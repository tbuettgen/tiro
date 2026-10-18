//! The keyboard ↔ app channel.
//!
//! iOS keyboards can't use the microphone, so the Tiro app does the
//! listening (the same split Wispr Flow uses). While a "session" is live the
//! app keeps an audio session running in the background; the keyboard sends
//! start / stop / cancel as Darwin notifications, and the app publishes its
//! state, the input level and the finished text through the shared
//! UserDefaults suite, poking the keyboard with a notification each time.

import Foundation
import notify

enum SessionPhase: String {
    case off           // no session: the keyboard must open the app first
    case idle          // session live, waiting for the keyboard's mic tap
    case recording
    case transcribing
    case done          // result ready (see Bridge.result)
    case error
}

enum Bridge {
    enum Command: String {
        case start = "dev.tiro.cmd.start"
        case stop = "dev.tiro.cmd.stop"
        case cancel = "dev.tiro.cmd.cancel"
        case endSession = "dev.tiro.cmd.end"
    }

    static let stateChanged = "dev.tiro.state"

    private enum Key {
        static let heartbeat = "bridge.heartbeat"
        static let phase = "bridge.phase"
        static let level = "bridge.level"
        static let message = "bridge.message"
        static let sessionEnds = "bridge.sessionEnds"
        static let resultID = "bridge.result.id"
        static let resultText = "bridge.result.text"
        static let consumedID = "bridge.result.consumed"
        static let wantsRecord = "bridge.wantsRecord"
    }

    private static var d: UserDefaults { Shared.defaults }

    // MARK: Notifications

    static func post(_ name: String) { notify_post(name) }
    static func send(_ c: Command) { post(c.rawValue) }

    /// Observe a Darwin notification on the main queue. Keep the token;
    /// pass it to `stopObserving` when done.
    @discardableResult
    static func observe(_ name: String, _ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, .main) { _ in handler() }
        return token
    }

    static func stopObserving(_ token: Int32) { notify_cancel(token) }

    // MARK: State written by the app

    /// The app is alive and listening for commands when its heartbeat is fresh.
    static var appIsListening: Bool {
        Date().timeIntervalSince1970 - d.double(forKey: Key.heartbeat) < 3.0 && phase != .off
    }

    static func beat() { d.set(Date().timeIntervalSince1970, forKey: Key.heartbeat) }

    static var phase: SessionPhase {
        get { SessionPhase(rawValue: d.string(forKey: Key.phase) ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: Key.phase) }
    }

    static func publish(_ phase: SessionPhase, message: String? = nil) {
        self.phase = phase
        d.set(message, forKey: Key.message)
        if phase == .off { d.set(0, forKey: Key.heartbeat) }
        post(stateChanged)
    }

    static var message: String? { d.string(forKey: Key.message) }

    static var level: Float {
        get { d.float(forKey: Key.level) }
        set { d.set(newValue, forKey: Key.level) }
    }

    static var sessionEnds: Date? {
        get { let t = d.double(forKey: Key.sessionEnds); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.sessionEnds) }
    }

    static func publishResult(_ text: String) {
        d.set(text, forKey: Key.resultText)
        d.set(UUID().uuidString, forKey: Key.resultID)
        publish(.done)
    }

    // MARK: Read by the keyboard

    /// The finished take, once. Returns nil when there is none or the
    /// keyboard already inserted it.
    static func takeResult() -> String? {
        guard let id = d.string(forKey: Key.resultID), id != d.string(forKey: Key.consumedID),
              let text = d.string(forKey: Key.resultText) else { return nil }
        d.set(id, forKey: Key.consumedID)
        return text
    }

    /// Set by the keyboard right before it opens the app, so the app starts
    /// recording as soon as it comes up. Valid for 30 s.
    static func requestRecordOnOpen() { d.set(Date().timeIntervalSince1970, forKey: Key.wantsRecord) }

    static func consumeRecordRequest() -> Bool {
        let t = d.double(forKey: Key.wantsRecord)
        d.set(0, forKey: Key.wantsRecord)
        return t > 0 && Date().timeIntervalSince1970 - t < 30
    }
}
