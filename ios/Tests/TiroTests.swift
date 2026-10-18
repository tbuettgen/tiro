import XCTest
@testable import Tiro

final class FormatterTests: XCTestCase {
    /// The shared vectors from spec/format_cases.json — the desktop's Rust
    /// tests run the same file.
    func testSharedFormatCases() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "format_cases", withExtension: "json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let defaults = try XCTUnwrap(root["defaults"] as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 40)
        func pairs(_ v: Any?) -> [FormatOptions.Pair] {
            (v as? [[String]] ?? []).map { FormatOptions.Pair($0[0], $0[1]) }
        }
        for c in cases {
            var o = defaults
            for (k, v) in c["options"] as? [String: Any] ?? [:] { o[k] = v }
            let opts = FormatOptions(
                cleanup: o["cleanup"] as! String,
                spokenCommands: o["spoken_commands"] as! Bool,
                style: o["style"] as! String,
                corrections: pairs(o["corrections"]),
                snippets: pairs(o["snippets"]))
            XCTAssertEqual(SmartFormatter.format(c["input"] as! String, opts), c["expected"] as? String, "\(c["name"]!)")
        }
    }

    func testContextFitter() {
        XCTAssertEqual(ContextFitter.fit("Hello there.", before: nil), "Hello there.")
        XCTAssertEqual(ContextFitter.fit("Hello there.", before: ""), "Hello there.")
        XCTAssertEqual(ContextFitter.fit("Hello there.", before: "Done. "), "Hello there.")
        XCTAssertEqual(ContextFitter.fit("Hello there.", before: "Done."), " Hello there.")
        XCTAssertEqual(ContextFitter.fit("And then we left.", before: "We ate dinner"), " and then we left.")
        XCTAssertEqual(ContextFitter.fit("I left.", before: "Then"), " I left.")
        XCTAssertEqual(ContextFitter.fit("NASA called.", before: "Then"), " NASA called.")
        XCTAssertEqual(ContextFitter.fit(", too.", before: "Me"), ", too.")
        XCTAssertEqual(ContextFitter.fit("Next line.", before: "First\n"), "Next line.")
    }

    func testNonSpeechCollapse() {
        XCTAssertEqual(NonSpeech.collapse("[BLANK_AUDIO]"), "")
        XCTAssertEqual(NonSpeech.collapse(" (silence) [ Music ] ♪ "), "")
        XCTAssertEqual(NonSpeech.collapse("*laughs*"), "")
        XCTAssertEqual(NonSpeech.collapse("[BLANK_AUDIO] hello"), "[BLANK_AUDIO] hello")
        XCTAssertEqual(NonSpeech.collapse("silence"), "silence")
        XCTAssertEqual(NonSpeech.collapse("[unclosed"), "[unclosed")
    }
}

final class WordListTests: XCTestCase {
    func testSnippetEscapingRoundTrips() {
        let pairs = [FormatOptions.Pair("sign off", "Best,\nTrevor"), FormatOptions.Pair("path", #"C:\Users\me"#)]
        let raw = WordLists.serializeSnippets(pairs)
        XCTAssertEqual(raw, "sign off => Best,\\nTrevor\npath => C:\\\\Users\\\\me\n")
        XCTAssertEqual(WordLists.parseSnippets(raw), pairs)
    }

    func testCorrectionsParsing() {
        let raw = "# comment\ntyro => Tiro\n\nbad line\n => empty\nc plus plus => C++\n"
        XCTAssertEqual(WordLists.parseCorrections(raw), [FormatOptions.Pair("tyro", "Tiro"), FormatOptions.Pair("c plus plus", "C++")])
    }

    func testInitialPrompt() {
        XCTAssertNil(WordLists.buildPrompt(hotwords: [], spokenCommands: false))
        XCTAssertEqual(WordLists.buildPrompt(hotwords: ["Tiro", "Beckett  Harriman"], spokenCommands: false), "Tiro Beckett Harriman.")
        XCTAssertEqual(WordLists.buildPrompt(hotwords: [], spokenCommands: true), WordLists.commandPrimer)
        XCTAssertEqual(WordLists.buildPrompt(hotwords: ["Tiro"], spokenCommands: true), "Tiro. " + WordLists.commandPrimer)
    }

    func testHotwordsSkipCommentsAndBlanks() {
        XCTAssertEqual(WordLists.parseHotwords("# words\n\nTiro\n  PipeWire  \n#x\n"), ["Tiro", "PipeWire"])
    }

    func testCleanTermStripsLineBreakers() {
        XCTAssertEqual(WordLists.cleanTerm("  # #hash tag  "), "hash tag")
        XCTAssertEqual(WordLists.cleanTerm("a => b"), "a b")
        XCTAssertNil(WordLists.cleanTerm("  ##  "))
    }
}

final class TranscriptStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func date(_ s: String) -> Date { TranscriptStore.tsFormatter.date(from: s)! }

    func testAppendWritesDesktopFormats() throws {
        TranscriptStore.append(verbatim: "hello world", clean: "Hello world.", model: "base.en", secs: 2.345,
                               now: date("2026-07-27T09:05:00"), dir: dir, save: true)
        TranscriptStore.append(verbatim: "second", clean: "Second.", model: "base.en", secs: 1,
                               now: date("2026-07-27T09:06:00"), dir: dir, save: true)
        let md = try String(contentsOf: dir.appendingPathComponent("2026-07-27.md"), encoding: .utf8)
        XCTAssertTrue(md.hasPrefix("# Tiro — 2026-07-27\n\n"))
        XCTAssertEqual(md.components(separatedBy: "# Tiro").count, 2, "header written once")
        XCTAssertTrue(md.hasSuffix("- **09:05** — hello world\n- **09:06** — second\n"))

        let recs = TranscriptStore.records(day: "2026-07-27", dir: dir)
        XCTAssertEqual(recs.map(\.text), ["second", "hello world"], "newest first")
        XCTAssertEqual(recs.last?.secs, 2.35)
        XCTAssertEqual(recs.last?.clean, "Hello world.")
        XCTAssertEqual(TranscriptStore.days(dir: dir), ["2026-07-27"])
    }

    func testSaveOffTouchesNothing() {
        let rec = TranscriptStore.append(verbatim: "x", clean: "X.", model: "m", secs: 1, dir: dir, save: false)
        XCTAssertEqual(rec.text, "x")
        XCTAssertTrue(TranscriptStore.days(dir: dir).isEmpty)
    }

    func testDeleteRewritesTheDay() {
        let a = TranscriptStore.append(verbatim: "keep", clean: "", model: "m", secs: 1, now: date("2026-07-27T10:00:00"), dir: dir, save: true)
        let b = TranscriptStore.append(verbatim: "drop", clean: "", model: "m", secs: 1, now: date("2026-07-27T10:01:00"), dir: dir, save: true)
        TranscriptStore.delete(b, dir: dir)
        XCTAssertEqual(TranscriptStore.records(day: "2026-07-27", dir: dir), [a])
        TranscriptStore.delete(a, dir: dir)
        XCTAssertTrue(TranscriptStore.days(dir: dir).isEmpty, "empty day removed")
    }

    func testCorruptLinesAreSkipped() throws {
        TranscriptStore.append(verbatim: "ok", clean: "", model: "m", secs: 1, now: date("2026-07-27T10:00:00"), dir: dir, save: true)
        let h = try FileHandle(forWritingTo: dir.appendingPathComponent("2026-07-27.jsonl"))
        try h.seekToEnd(); try h.write(contentsOf: Data("{not json\n".utf8)); try h.close()
        XCTAssertEqual(TranscriptStore.records(day: "2026-07-27", dir: dir).map(\.text), ["ok"])
    }

    func testStats() {
        func rec(_ ts: String, _ text: String, _ secs: Double) -> TranscriptRecord {
            TranscriptRecord(ts: ts, text: text, clean: "", mic: "", model: "", device: "cpu", secs: secs)
        }
        let today = date("2026-07-27T12:00:00")
        let records = [
            rec("2026-07-27T09:00:00", "one two three four five six", 3),
            rec("2026-07-26T09:00:00", "a b c d", 1),
            rec("2026-07-25T09:00:00", "x y", 2),
            rec("2026-07-20T09:00:00", "old", 0),
        ]
        let s = TranscriptStore.stats(records, today: today)
        XCTAssertEqual(s.takes, 4)
        XCTAssertEqual(s.words, 13)
        XCTAssertEqual(s.wpm, 130)         // 13 words in 6 s
        XCTAssertEqual(s.streak, 3)        // 25th–27th
        XCTAssertEqual(s.minutesSaved, 0)  // 13/40 min typing − 0.1 min talking → 0.225 → 0
        let yesterdayOnly = TranscriptStore.stats([rec("2026-07-26T09:00:00", "hi", 1)], today: today)
        XCTAssertEqual(yesterdayOnly.streak, 1, "streak can end yesterday")
        XCTAssertEqual(TranscriptStore.stats([], today: today), DictationStats())
        var big = DictationStats(); big.words = 4000; big.seconds = 1200
        XCTAssertEqual(big.minutesSaved, 80)  // 100 min typing − 20 min talking
    }
}

/// Real transcription through whisper.cpp. Needs a model: set
/// TIRO_TEST_MODEL (xcodebuild: TEST_RUNNER_TIRO_TEST_MODEL) to a
/// ggml-*.bin path on the Mac, which the simulator can read directly.
final class TranscriptionTests: XCTestCase {
    private func samples(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
        let data = try Data(contentsOf: url)
        // 16 kHz mono s16le WAV from `say`; find the "data" chunk.
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
        throw XCTSkip("no data chunk")
    }

    private func engine() throws -> WhisperEngine {
        guard let path = ProcessInfo.processInfo.environment["TIRO_TEST_MODEL"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Set TIRO_TEST_MODEL to a whisper model to run transcription tests")
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: "ggml-", with: "").replacingOccurrences(of: "-q8_0.bin", with: "").replacingOccurrences(of: ".bin", with: "")
        return try WhisperEngine(modelPath: URL(fileURLWithPath: path), modelName: name)
    }

    func testPlainSentence() async throws {
        let e = try engine()
        let start = Date()
        let text = try await e.transcribe(try samples("plain"), language: "en", prompt: nil, vadModel: ModelStore.vadModel)
        print("TIRO-E2E plain (\(String(format: "%.2f", Date().timeIntervalSince(start)))s): \(text)")
        XCTAssertTrue(text.lowercased().contains("quick brown fox"), text)
    }

    func testSpokenCommandsEndToEnd() async throws {
        let e = try engine()
        let verbatim = try await e.transcribe(try samples("dictation"), language: "en", prompt: WordLists.buildPrompt(hotwords: ["Beckett", "Tiro"], spokenCommands: true), vadModel: ModelStore.vadModel)
        let clean = SmartFormatter.format(verbatim, FormatOptions())
        print("TIRO-E2E verbatim: \(verbatim)")
        print("TIRO-E2E delivered: \(clean.debugDescription)")
        XCTAssertTrue(verbatim.contains("Beckett"), verbatim)
        XCTAssertTrue(clean.contains("\n"), "new line command applied")
        XCTAssertFalse(clean.lowercased().contains("scratch that"), "scratch that applied")
        XCTAssertFalse(clean.lowercased().contains("two"), "the scratched sentence is gone")
        XCTAssertTrue(clean.hasSuffix("See you soon."), clean)
    }

    func testSilenceIsEmpty() async throws {
        let e = try engine()
        let text = try await e.transcribe([Float](repeating: 0, count: 16_000 * 2), language: "en", prompt: nil, vadModel: ModelStore.vadModel)
        XCTAssertEqual(text, "")
    }
}
