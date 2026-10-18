//! The delivered-text pipeline from spec/FLOW_FEATURES.md, steps 1–10.
//! The desktop app runs the same pipeline (src-tauri/src/format.rs) against
//! the same test vectors (spec/format_cases.json). Only the delivered copy
//! is formatted: the verbatim transcript is always what gets logged.

import Foundation

struct FormatOptions: Equatable {
    var cleanup: String = "light"          // none | light | fillers
    var spokenCommands: Bool = true
    var style: String = "formal"           // formal | casual | very_casual
    var corrections: [Pair] = []
    var snippets: [Pair] = []

    struct Pair: Equatable, Hashable {
        var from: String
        var to: String
        init(_ from: String, _ to: String) { self.from = from; self.to = to }
    }
}

enum SmartFormatter {
    static func format(_ verbatim: String, _ o: FormatOptions) -> String {
        // 1. Whitespace.
        let collapsed = collapseWhitespace(verbatim)
        if collapsed.isEmpty { return "" }

        // 2. Whole-take snippet: the expansion exactly as saved.
        let said = normalizeForSnippet(collapsed)
        if !said.isEmpty, let hit = o.snippets.first(where: { normalizeForSnippet($0.from) == said }) {
            return hit.to
        }

        var t = collapsed
        if o.cleanup != "none" {
            // 4. Spoken commands.
            if o.spokenCommands {
                t = applySpokenCommands(t)
                if t.isEmpty { return "" }
            }
            // 5. Fillers.
            if o.cleanup == "fillers" {
                t = stripFillers(t)
            }
            if t.isEmpty {
                t = collapsed // an all-filler take is delivered as said
            } else {
                // 6. Light rules, 7. style.
                t = applyStyle(lightRules(t), o.style)
                if t.isEmpty { t = collapsed }
            }
        }
        // 9. Corrections, 10. inline snippets.
        t = replacePhrases(t, o.corrections)
        t = replacePhrases(t, o.snippets)
        return t
    }

    // MARK: - Step 1–2 helpers

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func normalizeForSnippet(_ s: String) -> String {
        let kept = s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
        return collapseWhitespace(kept)
    }

    // MARK: - Step 4: spoken commands

    private static let breakCommands: [(String, String)] = [
        (#"[ \t]*\bnew[ \t]+paragraph\b[,.;:!?]*[ \t]*"#, "\n\n"),
        (#"[ \t]*\bnew[ \t]+line\b[,.;:!?]*[ \t]*"#, "\n"),
    ]

    private static let punctuationCommands: [(String, String)] = [
        ("question[ \\t]+mark", "?"),
        ("exclamation[ \\t]+point", "!"),
        ("exclamation[ \\t]+mark", "!"),
        ("full[ \\t]+stop", "."),
        ("semicolon", ";"),
        ("colon", ":"),
        ("comma", ","),
        ("period", "."),
    ]

    /// Words that make a following "period" the ordinary noun.
    private static let periodNounWords: Set<String> = [
        "a", "an", "the", "this", "that", "each", "every", "any", "some", "which", "what",
        "trial", "grace", "waiting", "cooling", "probation", "billing",
    ]

    private static let deleteCommand = #"\b(?:scratch|delete|strike)[ \t]+that\b[,.;:!?]*[ \t]*"#

    static func applySpokenCommands(_ input: String) -> String {
        var t = input
        // Pass 1: line breaks.
        for (pattern, replacement) in breakCommands {
            t = regexReplace(t, pattern, template: NSRegularExpression.escapedTemplate(for: replacement), caseInsensitive: true)
        }
        // Pass 2: punctuation.
        for (words, mark) in punctuationCommands {
            let pattern = #"[ \t,.;:!?]*\b"# + words + #"\b[,.;:!?]*[ \t]*"#
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = NSMutableString(string: t)
            let matches = re.matches(in: t, range: NSRange(location: 0, length: ns.length))
            for m in matches.reversed() {
                if mark == ".", words == "period" {
                    let before = ns.substring(to: m.range.location)
                    if periodNounWords.contains(lastWord(before)) { continue }
                }
                ns.replaceCharacters(in: m.range, with: mark + " ")
            }
            t = ns as String
        }
        // Pass 3: deletion, first occurrence each time until none are left.
        if let re = try? NSRegularExpression(pattern: deleteCommand, options: [.caseInsensitive]) {
            while true {
                let ns = NSMutableString(string: t)
                guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { break }
                var start = 0
                var i = m.range.location - 1
                while i >= 0 {
                    let c = ns.character(at: i)
                    if c == 0x2E || c == 0x21 || c == 0x3F || c == 0x0A { // . ! ? \n
                        start = i + 1
                        break
                    }
                    i -= 1
                }
                let end = m.range.location + m.range.length
                ns.replaceCharacters(in: NSRange(location: start, length: end - start), with: " ")
                t = ns as String
            }
        }
        // Tidy.
        t = regexReplace(t, #"[ \t]+"#, template: " ")
        t = regexReplace(t, #"[ \t]+(?=[,.;:!?])"#, template: "")
        t = trimLines(t)
        t = regexReplace(t, #"\n{3,}"#, template: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last run of letters/digits in `s`, lowercased ("" when none).
    private static func lastWord(_ s: String) -> String {
        var word: [Character] = []
        for c in s.reversed() {
            if c.isLetter || c.isNumber || c == "'" || c == "’" {
                word.append(c)
            } else if !word.isEmpty {
                break
            }
        }
        return String(word.reversed()).lowercased()
    }

    // MARK: - Step 5: fillers

    static func stripFillers(_ input: String) -> String {
        var t = regexReplace(input, #"\b(um+|uh+|erm+|hmm+)\b,?[ \t]*"#, template: "", caseInsensitive: true)
        t = regexReplace(t, #"[ \t]+"#, template: " ")
        t = trimLines(t)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step 6: light rules

    static func lightRules(_ input: String) -> String {
        var t = regexReplace(input, #"[ \t]+([,.!?;:])"#, template: "$1")
        t = regexReplace(t, #"\bi\b"#, template: "I")
        t = t.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let first = line.first else { return String(line) }
                return first.uppercased() + line.dropFirst()
            }
            .joined(separator: "\n")
        if let last = t.last, !".!?".contains(last) {
            t.append(".")
        }
        return t
    }

    // MARK: - Step 7: style

    static func applyStyle(_ input: String, _ style: String) -> String {
        var t = input
        guard style == "casual" || style == "very_casual" else { return t }
        if t.hasSuffix("."), !t.hasSuffix("..") {
            t.removeLast()
        }
        guard style == "very_casual" else { return t }

        var chars = Array(t)
        var i = 0
        while i < chars.count {
            let atStart = i == 0
                || chars[i - 1] == "\n"
                || (i >= 2 && chars[i - 1] == " " && ".!?".contains(chars[i - 2]))
            if atStart {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j] == "'" || chars[j] == "’" { j += 1 }
                if j > i, chars[i].isLetter {
                    let word = String(chars[i..<j])
                    let isI = word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")
                    let restLower = word.dropFirst().filter { $0.isLetter }.allSatisfy { $0.isLowercase }
                    if !isI, restLower {
                        let lowered = Array(String(chars[i]).lowercased())
                        if lowered.count == 1 { chars[i] = lowered[0] }
                    }
                }
            }
            i += 1
        }
        return String(chars)
    }

    // MARK: - Steps 9–10: literal phrase replacement

    /// Case-insensitive literal replacement, `\b` only on the sides of
    /// `from` that start/end with a word character (so ".NET" and "C++"
    /// still match). The replacement is inserted literally. A rule set that
    /// blanks the text is ignored (never lose a take).
    static func replacePhrases(_ text: String, _ pairs: [FormatOptions.Pair]) -> String {
        guard !pairs.isEmpty, !text.isEmpty else { return text }
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        var out = text
        for p in pairs where !p.from.isEmpty {
            let lead = p.from.first.map(isWord) == true ? #"\b"# : ""
            let trail = p.from.last.map(isWord) == true ? #"\b"# : ""
            let pattern = lead + NSRegularExpression.escapedPattern(for: p.from) + trail
            out = regexReplace(out, pattern, template: NSRegularExpression.escapedTemplate(for: p.to), caseInsensitive: true)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : out
    }

    // MARK: - Utilities

    private static func trimLines(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            .joined(separator: "\n")
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    static func regexReplace(_ s: String, _ pattern: String, template: String, caseInsensitive: Bool = false) -> String {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        cacheLock.lock()
        var re = regexCache[key]
        if re == nil {
            re = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
            regexCache[key] = re
        }
        cacheLock.unlock()
        guard let re else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

/// Keyboard-only: fit a take to the text around the cursor, the way a person
/// typing would (a space after a word, lowercase when continuing a sentence).
enum ContextFitter {
    static func fit(_ text: String, before: String?) -> String {
        guard !text.isEmpty, let before, !before.isEmpty else { return text }
        var out = text
        let lastChar = before.last!
        let continuing = before.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).last.map { !".!?\n".contains($0) } ?? false
        if continuing, let firstWord = out.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).first {
            let w = String(firstWord)
            let isI = w == "I" || w.hasPrefix("I'") || w.hasPrefix("I’")
            if !isI, w.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }), out.first?.isUppercase == true {
                out = out.prefix(1).lowercased() + out.dropFirst()
            }
        }
        if !lastChar.isWhitespace, let first = out.first, !",.;:!?)".contains(first) {
            out = " " + out
        }
        return out
    }
}
