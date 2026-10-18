//! The take pipeline (desktop: flow.rs): record → transcribe locally →
//! format the delivered copy → log the verbatim take → deliver.
//!
//! Two ways in:
//! - in the app: the big mic button; the result is shown and copied;
//! - from the Tiro keyboard: a background "session" (Bridge.swift). The
//!   keyboard opens the app once to start it, then drives start/stop from
//!   any app while Tiro listens in the background, until the session idles
//!   out after `session_minutes`.

import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class Dictation: ObservableObject {
    enum Origin { case app, keyboard }

    @Published private(set) var recording = false
    @Published private(set) var transcribing = false
    @Published private(set) var level: Float = 0
    @Published private(set) var lastResult: TranscriptRecord?
    @Published var errorMessage: String?
    @Published private(set) var sessionActive = false
    @Published private(set) var sessionEnds: Date?
    @Published private(set) var lastOrigin: Origin = .app
    /// Bumped after every saved take so lists and stats reload.
    @Published private(set) var revision = 0

    let models: ModelStore
    private let recorder = AudioRecorder()
    private var engine: WhisperEngine?
    private var origin: Origin = .app
    private var heartbeat: Timer?
    private var lastActivity = Date()
    private var tokens: [Int32] = []
    private var take = 0               // stale-finish protection, like flow.rs session ids
    private var levelStamp: TimeInterval = 0

    init(models: ModelStore) {
        self.models = models
        Bridge.publish(.off)

        recorder.onLevel = { [weak self] lvl in
            let now = Date().timeIntervalSince1970
            Task { @MainActor in
                guard let self, self.recording else { return }
                self.level = lvl
                if now - self.levelStamp > 0.06 {
                    self.levelStamp = now
                    Bridge.level = lvl
                }
            }
        }

        tokens.append(Bridge.observe(Bridge.Command.start.rawValue) { [weak self] in
            Task { @MainActor in self?.keyboardStart() }
        })
        tokens.append(Bridge.observe(Bridge.Command.stop.rawValue) { [weak self] in
            Task { @MainActor in self?.stop() }
        })
        tokens.append(Bridge.observe(Bridge.Command.cancel.rawValue) { [weak self] in
            Task { @MainActor in self?.cancel() }
        })
        tokens.append(Bridge.observe(Bridge.Command.endSession.rawValue) { [weak self] in
            Task { @MainActor in self?.endSession() }
        })

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Task { @MainActor in self?.handleInterruption(type) }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rearmIfNeeded() }
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rearmIfNeeded() }
        }
    }

    // MARK: - In-app

    func toggleInApp() {
        if recording { stop() } else { Task { await start(.app) } }
    }

    // MARK: - Keyboard session

    /// Opened from the keyboard (tiro://dictate): start a session and, if the
    /// keyboard asked, start recording right away so the user can swipe back
    /// and talk.
    func openedFromKeyboard() {
        let record = Bridge.consumeRecordRequest()
        Task {
            await startSession()
            if record, sessionActive, !recording { await start(.keyboard) }
        }
    }

    func startSession() async {
        guard await ensureMicPermission() else { return }
        do {
            try recorder.arm()
        } catch {
            fail(error.localizedDescription, origin: .keyboard)
            return
        }
        sessionActive = true
        lastActivity = Date()
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        if !recording && !transcribing { Bridge.publish(.idle) }
    }

    func endSession() {
        if recording { cancel() }
        heartbeat?.invalidate()
        heartbeat = nil
        sessionActive = false
        sessionEnds = nil
        Bridge.sessionEnds = nil
        if !recording && !transcribing { recorder.disarm() }
        Bridge.publish(.off)
    }

    private func tick() {
        guard sessionActive else { return }
        Bridge.beat()
        if recording || transcribing { lastActivity = Date() }
        let ends = lastActivity.addingTimeInterval(TimeInterval(Settings.sessionMinutes * 60))
        sessionEnds = ends
        Bridge.sessionEnds = ends
        if Date() >= ends { endSession() }
    }

    private func keyboardStart() {
        guard !recording else { return }
        Task { await start(.keyboard) }
    }

    // MARK: - Recording

    func start(_ origin: Origin) async {
        guard !recording else { return }
        errorMessage = nil
        guard await ensureMicPermission() else { return }
        if transcribing { engine?.cancel(); take += 1; transcribing = false }
        do {
            if !recorder.isArmed { try recorder.arm() }
        } catch {
            fail(error.localizedDescription, origin: origin)
            return
        }
        self.origin = origin
        lastOrigin = origin
        take += 1
        lastActivity = Date()
        recorder.begin()
        recording = true
        if origin == .keyboard || sessionActive { Bridge.publish(.recording) }
    }

    func stop() {
        guard recording else { return }
        let samples = recorder.finish()
        recording = false
        level = 0
        Bridge.level = 0
        lastActivity = Date()
        let secs = Double(samples.count) / AudioRecorder.sampleRate
        let origin = self.origin
        if !sessionActive { recorder.disarm() }

        guard secs >= 0.3 else { // no empty takes
            publishIdle()
            return
        }
        transcribing = true
        if origin == .keyboard || sessionActive { Bridge.publish(.transcribing) }
        let myTake = take
        let bg = UIApplication.shared.beginBackgroundTask(withName: "transcribe")
        Task {
            defer { UIApplication.shared.endBackgroundTask(bg) }
            do {
                let engine = try loadEngine()
                let verbatim = try await engine.transcribe(
                    samples, language: Settings.language, prompt: WordLists.vocabPrompt(), vadModel: ModelStore.vadModel)
                guard myTake == take else { return } // a newer take started; drop this one
                transcribing = false
                finish(verbatim: verbatim, secs: secs, model: engine.modelName, origin: origin)
            } catch is CancellationError {
                if myTake == take { transcribing = false; publishIdle() }
            } catch {
                guard myTake == take else { return }
                transcribing = false
                fail(error.localizedDescription, origin: origin)
            }
        }
    }

    func cancel() {
        if recording {
            _ = recorder.finish()
            recording = false
            level = 0
            if !sessionActive { recorder.disarm() }
        }
        if transcribing {
            engine?.cancel()
            transcribing = false
        }
        take += 1
        publishIdle()
    }

    private func finish(verbatim: String, secs: Double, model: String, origin: Origin) {
        guard !verbatim.isEmpty else { // silence: nothing delivered, nothing logged
            publishIdle(message: "Didn't catch that")
            return
        }
        let clean = SmartFormatter.format(verbatim, Settings.formatOptions())
        let rec = TranscriptStore.append(verbatim: verbatim, clean: clean, model: model, secs: secs)
        lastResult = rec
        revision += 1
        if !clean.isEmpty { UIPasteboard.general.string = clean }
        if origin == .keyboard {
            if clean.isEmpty { publishIdle() } else { Bridge.publishResult(clean) }
        } else if sessionActive {
            publishIdle()
        }
    }

    private func publishIdle(message: String? = nil) {
        Bridge.publish(sessionActive ? .idle : .off, message: message)
    }

    private func fail(_ message: String, origin: Origin) {
        errorMessage = message
        if origin == .keyboard || sessionActive {
            Bridge.publish(.error, message: message)
        }
    }

    // MARK: - Engine

    private func loadEngine() throws -> WhisperEngine {
        let wanted = Settings.model
        if let engine, engine.modelName == wanted { return engine }
        let candidates = [ModelStore.model(named: wanted)].compactMap { $0 } + ModelStore.catalog
        guard let m = candidates.first(where: ModelStore.isInstalled) else {
            throw NSError(domain: "Tiro", code: 4, userInfo: [NSLocalizedDescriptionKey: "Download a speech model first (Settings → Model)."])
        }
        if let engine, engine.modelName == m.name { return engine }
        engine = nil // free the old model before loading the next
        let e = try WhisperEngine(modelPath: ModelStore.path(for: m), modelName: m.name)
        engine = e
        return e
    }

    /// Drop the loaded model (memory warning, or the model was changed).
    func unloadEngine() {
        if !transcribing { engine = nil }
    }

    // MARK: - Audio session housekeeping

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            if recording { stop() }
        case .ended:
            rearmIfNeeded()
        default:
            break
        }
    }

    private func rearmIfNeeded() {
        guard sessionActive || recording else { return }
        do { try recorder.rearm() } catch { fail(error.localizedDescription, origin: origin) }
    }

    private func ensureMicPermission() async -> Bool {
        #if DEBUG
        if AudioRecorder.usesFakeMic { return true }
        #endif
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            fail("Tiro needs the microphone. Turn it on in Settings → Tiro → Microphone.", origin: origin)
            return false
        default:
            let ok = await AVAudioApplication.requestRecordPermission()
            if !ok { fail("Tiro needs the microphone to hear you.", origin: origin) }
            return ok
        }
    }
}
