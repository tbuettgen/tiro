//! Transcripts in the desktop app's format: one JSONL and one Markdown file
//! per day. `text` is always the verbatim take; `clean` is what was delivered.

import Foundation

struct TranscriptRecord: Codable, Identifiable, Hashable {
    var ts: String      // yyyy-MM-dd'T'HH:mm:ss, local time
    var text: String
    var clean: String
    var mic: String
    var model: String
    var device: String
    var secs: Double

    var id: String { ts + "|" + String(text.hashValue % 100_000) }
    var shown: String { clean.isEmpty ? text : clean }
    var day: String { String(ts.prefix(10)) }

    var date: Date? { TranscriptStore.tsFormatter.date(from: ts) }
}

struct DictationStats: Equatable {
    var words = 0
    var takes = 0
    var seconds = 0.0
    var streak = 0

    var wpm: Int { seconds > 0 ? Int((Double(words) / seconds * 60).rounded()) : 0 }
    /// Minutes saved versus typing at 40 WPM, never negative.
    var minutesSaved: Int { max(0, Int(((Double(words) / 40.0) - seconds / 60.0).rounded(.down))) }
}

enum TranscriptStore {
    static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let lock = NSLock()

    /// Append a take. With saving off nothing touches disk; the record is
    /// still returned so the current screen can show it.
    @discardableResult
    static func append(verbatim: String, clean: String, model: String, secs: Double,
                       now: Date = Date(), dir: URL = Shared.transcriptsDir,
                       save: Bool = Settings.saveTranscripts) -> TranscriptRecord {
        let rec = TranscriptRecord(
            ts: tsFormatter.string(from: now), text: verbatim, clean: clean,
            mic: "iPhone", model: model, device: "cpu", secs: (secs * 100).rounded() / 100)
        guard save else { return rec }
        lock.lock(); defer { lock.unlock() }
        let day = dayFormatter.string(from: now)
        if let data = try? JSONEncoder.sorted.encode(rec), var line = String(data: data, encoding: .utf8) {
            line.append("\n")
            appendText(line, to: dir.appendingPathComponent("\(day).jsonl"))
        }
        let md = dir.appendingPathComponent("\(day).md")
        var chunk = FileManager.default.fileExists(atPath: md.path) ? "" : markdownHeader(day)
        chunk += "- **\(rec.ts.dropFirst(11).prefix(5))** — \(verbatim)\n"
        appendText(chunk, to: md)
        return rec
    }

    static func markdownHeader(_ day: String) -> String {
        "# Tiro — \(day)\n\nVerbatim dictation capture (raw layer; the refine-transcript pipeline cleans this later). One line per utterance.\n\n"
    }

    /// Days with a transcript file, newest first.
    static func days(dir: URL = Shared.transcriptsDir) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { $0.hasSuffix(".jsonl") ? String($0.dropLast(6)) : nil }
            .filter { dayFormatter.date(from: $0) != nil }
            .sorted(by: >)
    }

    /// One day's records, newest first. Corrupt lines are skipped.
    static func records(day: String, dir: URL = Shared.transcriptsDir) -> [TranscriptRecord] {
        guard let raw = try? String(contentsOf: dir.appendingPathComponent("\(day).jsonl"), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return raw.split(separator: "\n").compactMap { try? dec.decode(TranscriptRecord.self, from: Data($0.utf8)) }.reversed()
    }

    static func allRecords(dir: URL = Shared.transcriptsDir) -> [TranscriptRecord] {
        days(dir: dir).flatMap { records(day: $0, dir: dir) }
    }

    /// Remove one take from its day, rewriting both files.
    static func delete(_ rec: TranscriptRecord, dir: URL = Shared.transcriptsDir) {
        lock.lock(); defer { lock.unlock() }
        let kept = records(day: rec.day, dir: dir).reversed().filter { $0 != rec }
        rewrite(day: rec.day, records: Array(kept), dir: dir)
    }

    static func deleteAll(dir: URL = Shared.transcriptsDir) {
        lock.lock(); defer { lock.unlock() }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where name.hasSuffix(".jsonl") || name.hasSuffix(".md") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func rewrite(day: String, records: [TranscriptRecord], dir: URL) {
        let jsonl = dir.appendingPathComponent("\(day).jsonl")
        let md = dir.appendingPathComponent("\(day).md")
        if records.isEmpty {
            try? FileManager.default.removeItem(at: jsonl)
            try? FileManager.default.removeItem(at: md)
            return
        }
        let lines = records.compactMap { r -> String? in
            guard let d = try? JSONEncoder.sorted.encode(r) else { return nil }
            return String(data: d, encoding: .utf8).map { $0 + "\n" }
        }.joined()
        try? lines.data(using: .utf8)?.write(to: jsonl, options: .atomic)
        let body = records.map { "- **\($0.ts.dropFirst(11).prefix(5))** — \($0.text)\n" }.joined()
        try? (markdownHeader(day) + body).data(using: .utf8)?.write(to: md, options: .atomic)
    }

    private static func appendText(_ s: String, to url: URL) {
        let data = Data(s.utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Stats

    static func stats(_ records: [TranscriptRecord], today: Date = Date()) -> DictationStats {
        var s = DictationStats()
        s.takes = records.count
        for r in records {
            s.words += r.shown.split(whereSeparator: { $0.isWhitespace }).count
            s.seconds += r.secs
        }
        let days = Set(records.map(\.day))
        let cal = Calendar(identifier: .gregorian)
        var cursor = cal.startOfDay(for: today)
        if !days.contains(dayFormatter.string(from: cursor)) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        while days.contains(dayFormatter.string(from: cursor)) {
            s.streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return s
    }
}

extension JSONEncoder {
    /// Stable key order, like the desktop's serde output.
    static let sorted: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
