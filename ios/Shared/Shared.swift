//! Everything the app and the keyboard both see: the App Group container,
//! the settings (shared UserDefaults suite), and the file names.
//! Mirrors the desktop app's config keys where a setting exists on both.

import Foundation

enum Shared {
    /// The App Group id, injected into both Info.plists from Signing.xcconfig.
    static let appGroup: String = {
        (Bundle.main.object(forInfoDictionaryKey: "TiroAppGroup") as? String) ?? "group.dev.tiro.ios"
    }()

    /// The shared container. Falls back to the process's own Application
    /// Support when the group is unavailable (keyboard without Full Access,
    /// or unit tests), so nothing crashes; the keyboard detects that case.
    static let container: URL = {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tiro", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var hasGroupContainer: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard

    static var transcriptsDir: URL { dir("Transcripts") }
    static var listsDir: URL { dir("Lists") }

    private static func dir(_ name: String) -> URL {
        let url = container.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// User settings. Keys follow the desktop's config.ini names.
enum Settings {
    enum Key {
        static let cleanup = "clipboard_cleanup"       // none | light | fillers
        static let spokenCommands = "spoken_commands"  // bool
        static let style = "style"                     // formal | casual | very_casual
        static let language = "language"               // en | auto | <code>
        static let model = "model"                     // catalog name, e.g. base.en
        static let useVocabBias = "use_vocab_bias"     // bool
        static let saveTranscripts = "save_transcripts" // bool
        static let sessionMinutes = "session_minutes"  // keyboard session idle timeout
        static let haptics = "haptics"                 // bool
        static let fitToContext = "fit_to_context"     // keyboard: match spacing/case of the text around the cursor
        static let onboarded = "onboarded"
    }

    static func register() {
        Shared.defaults.register(defaults: [
            Key.cleanup: "light",
            Key.spokenCommands: true,
            Key.style: "formal",
            Key.language: "en",
            Key.model: "base.en",
            Key.useVocabBias: true,
            Key.saveTranscripts: true,
            Key.sessionMinutes: 5,
            Key.haptics: true,
            Key.fitToContext: true,
            Key.onboarded: false,
        ])
    }

    static var cleanup: String { Shared.defaults.string(forKey: Key.cleanup) ?? "light" }
    static var spokenCommands: Bool { Shared.defaults.object(forKey: Key.spokenCommands) as? Bool ?? true }
    static var style: String { Shared.defaults.string(forKey: Key.style) ?? "formal" }
    static var language: String { Shared.defaults.string(forKey: Key.language) ?? "en" }
    static var model: String { Shared.defaults.string(forKey: Key.model) ?? "base.en" }
    static var useVocabBias: Bool { Shared.defaults.object(forKey: Key.useVocabBias) as? Bool ?? true }
    static var saveTranscripts: Bool { Shared.defaults.object(forKey: Key.saveTranscripts) as? Bool ?? true }
    static var sessionMinutes: Int { max(1, Shared.defaults.object(forKey: Key.sessionMinutes) as? Int ?? 5) }
    static var haptics: Bool { Shared.defaults.object(forKey: Key.haptics) as? Bool ?? true }
    static var fitToContext: Bool { Shared.defaults.object(forKey: Key.fitToContext) as? Bool ?? true }

    /// The options the formatter runs with right now.
    static func formatOptions() -> FormatOptions {
        FormatOptions(
            cleanup: cleanup,
            spokenCommands: spokenCommands,
            style: style,
            corrections: WordLists.corrections(),
            snippets: WordLists.snippets()
        )
    }
}
