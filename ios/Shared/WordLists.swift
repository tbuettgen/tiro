//! Hot words, corrections and snippets, stored in the same line formats as
//! the desktop app (vocab.txt, corrections.txt, snippets.txt) so the files
//! can be copied between machines.

import Foundation

enum WordLists {
    static var vocabURL: URL { Shared.listsDir.appendingPathComponent("vocab.txt") }
    static var correctionsURL: URL { Shared.listsDir.appendingPathComponent("corrections.txt") }
    static var snippetsURL: URL { Shared.listsDir.appendingPathComponent("snippets.txt") }

    // MARK: Hot words

    static func hotwords() -> [String] { parseHotwords(read(vocabURL)) }

    static func parseHotwords(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func setHotwords(_ words: [String]) {
        write(vocabURL, words.compactMap(cleanTerm).map { $0 + "\n" }.joined())
    }

    /// The Whisper initial prompt (spec: "Initial prompt"): hot words, then
    /// the spoken-command words when those are on, or nil.
    static func vocabPrompt() -> String? {
        let words = Settings.useVocabBias ? hotwords() : []
        let commands = Settings.spokenCommands && Settings.cleanup != "none"
        return buildPrompt(hotwords: words, spokenCommands: commands)
    }

    static let commandPrimer = "Comma, period, question mark, new line, new paragraph, scratch that."

    static func buildPrompt(hotwords: [String], spokenCommands: Bool) -> String? {
        var parts: [String] = []
        let words = SmartFormatter.collapseWhitespace(hotwords.joined(separator: " "))
        if !words.isEmpty { parts.append(words + ".") }
        if spokenCommands { parts.append(commandPrimer) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Corrections

    static func corrections() -> [FormatOptions.Pair] { parseCorrections(read(correctionsURL)) }

    static func parseCorrections(_ raw: String) -> [FormatOptions.Pair] {
        raw.components(separatedBy: .newlines).compactMap { line in
            let ln = line.trimmingCharacters(in: .whitespaces)
            guard !ln.isEmpty, !ln.hasPrefix("#"), let r = ln.range(of: "=>") else { return nil }
            let heard = ln[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let written = ln[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty, !written.isEmpty else { return nil }
            return FormatOptions.Pair(heard, written)
        }
    }

    static func setCorrections(_ pairs: [FormatOptions.Pair]) {
        let lines = pairs.compactMap { p -> String? in
            guard let h = cleanTerm(p.from), let w = cleanTerm(p.to) else { return nil }
            return "\(h) => \(w)\n"
        }
        write(correctionsURL, lines.joined())
    }

    // MARK: Snippets

    static func snippets() -> [FormatOptions.Pair] { parseSnippets(read(snippetsURL)) }

    static func parseSnippets(_ raw: String) -> [FormatOptions.Pair] {
        raw.components(separatedBy: "\n").compactMap { line in
            let ln = line.trimmingCharacters(in: .whitespaces)
            guard !ln.isEmpty, !ln.hasPrefix("#"), let r = ln.range(of: "=>") else { return nil }
            let trigger = ln[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let expansion = unescape(String(ln[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            guard !trigger.isEmpty, !expansion.isEmpty else { return nil }
            return FormatOptions.Pair(trigger, expansion)
        }
    }

    static func serializeSnippets(_ pairs: [FormatOptions.Pair]) -> String {
        pairs.compactMap { p -> String? in
            guard let t = cleanTerm(p.from) else { return nil }
            let e = p.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !e.isEmpty else { return nil }
            return "\(t) => \(escape(e))\n"
        }.joined()
    }

    static func setSnippets(_ pairs: [FormatOptions.Pair]) {
        write(snippetsURL, serializeSnippets(pairs))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "\\": out.append("\\")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }

    // MARK: Files

    /// Strip characters that would corrupt the line formats: newlines,
    /// the `=>` arrow, and leading `#` (it would turn into a comment).
    static func cleanTerm(_ s: String) -> String? {
        var t = SmartFormatter.collapseWhitespace(s.replacingOccurrences(of: "=>", with: " "))
        while t.hasPrefix("#") {
            t = String(t.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty ? nil : t
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static func write(_ url: URL, _ content: String) {
        try? content.data(using: .utf8)?.write(to: url, options: .atomic)
    }
}
