//! Microphone capture. The engine runs "armed" for the whole session (iOS
//! only lets a background app record if the recording started while it was
//! in front), and samples are kept only between begin() and finish().
//! Output is what whisper.cpp wants: 16 kHz mono Float32.

import AVFoundation

final class AudioRecorder {
    static let sampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!

    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false

    /// Called on the audio thread with a 0…1 level, ~20 times a second.
    var onLevel: ((Float) -> Void)?

    private(set) var isArmed = false

    func arm() throws {
        guard !isArmed else { return }
        #if DEBUG
        if fake != nil { isArmed = true; return }
        #endif
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Tiro", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone is available."])
        }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isArmed = true
    }

    func disarm() {
        guard isArmed else { return }
        #if DEBUG
        if fake != nil { stopFake(); isArmed = false; lock.lock(); capturing = false; samples.removeAll(); lock.unlock(); return }
        #endif
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isArmed = false
        lock.lock(); capturing = false; samples.removeAll(); lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Restart after an interruption (a call) or a route change.
    func rearm() throws {
        #if DEBUG
        if fake != nil { return }
        #endif
        let wasCapturing = isCapturing
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isArmed = false
        try arm()
        lock.lock(); capturing = wasCapturing; lock.unlock()
    }

    var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capturing }

    func begin() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
        #if DEBUG
        startFake()
        #endif
    }

    /// Stop keeping samples and hand back the take.
    func finish() -> [Float] {
        #if DEBUG
        stopFake()
        #endif
        lock.lock(); defer { lock.unlock() }
        capturing = false
        let out = samples
        samples.removeAll()
        return out
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData?[0] else { return }
        let n = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: ch, count: n)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
        // ~-50 dB → 0, ~-10 dB → 1
        let db = 20 * log10(max(rms, 1e-6))
        onLevel?(min(1, max(0, (db + 50) / 40)))

        lock.lock()
        if capturing { samples.append(contentsOf: chunk) }
        lock.unlock()
    }

    /// Read a 16 kHz mono 16-bit WAV (what `say --data-format=LEI16@16000`
    /// writes) into samples.
    static func readWAV(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        var i = 12
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let len = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
            if id == "data" {
                let body = data[(i + 8)..<min(data.count, i + 8 + len)]
                return body.withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
                }
            }
            i += 8 + len + (len & 1)
        }
        return nil
    }

    // MARK: - Debug: a fake microphone for UI tests

    #if DEBUG
    /// TIRO_FAKE_MIC=<wav path>: "record" that file in real time instead of
    /// the microphone, so UI tests can drive the whole pipeline.
    private lazy var fake: [Float]? = ProcessInfo.processInfo.environment["TIRO_FAKE_MIC"]
        .map { URL(fileURLWithPath: $0) }.flatMap(AudioRecorder.readWAV)
    private var fakeTimer: DispatchSourceTimer?
    private var fakeCursor = 0

    static var usesFakeMic: Bool { ProcessInfo.processInfo.environment["TIRO_FAKE_MIC"] != nil }

    private func startFake() {
        guard let fake else { return }
        stopFake()
        fakeCursor = 0
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        t.schedule(deadline: .now(), repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let n = 1600
            let end = min(fake.count, self.fakeCursor + n)
            let chunk = self.fakeCursor < end ? Array(fake[self.fakeCursor..<end]) : [Float](repeating: 0, count: n)
            self.fakeCursor = end
            var sum: Float = 0
            for s in chunk { sum += s * s }
            let rms = (sum / Float(max(1, chunk.count))).squareRoot()
            self.onLevel?(min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40)))
            self.lock.lock()
            if self.capturing { self.samples.append(contentsOf: chunk) }
            self.lock.unlock()
        }
        t.resume()
        fakeTimer = t
    }

    private func stopFake() {
        fakeTimer?.cancel()
        fakeTimer = nil
    }
    #endif
}
