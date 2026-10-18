//! whisper.cpp, in process. Mirrors the desktop's CPU path
//! (src-tauri/src/transcribe.rs): greedy decoding, Silero VAD, the vocab
//! list as the initial prompt, and whisper's non-speech markers collapsed
//! to an empty take. It runs on the CPU on purpose: iOS refuses GPU work
//! from a background app, and keyboard takes are transcribed while Tiro is
//! in the background.

import Foundation
import whisper

final class WhisperEngine {
    let modelName: String
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.tiro.whisper", qos: .userInitiated)
    /// Read by whisper's abort callback on the decode thread.
    private let abortFlag: UnsafeMutablePointer<Bool> = {
        let p = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        p.initialize(to: false)
        return p
    }()

    init(modelPath: URL, modelName: String) throws {
        self.modelName = modelName
        var cp = whisper_context_default_params()
        cp.use_gpu = false
        cp.flash_attn = false
        guard let c = whisper_init_from_file_with_params(modelPath.path, cp) else {
            throw NSError(domain: "Tiro", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't load the \(modelName) model. Try downloading it again."])
        }
        ctx = c
    }

    deinit {
        if let ctx { whisper_free(ctx) }
        abortFlag.deallocate()
    }

    static var threadCount: Int32 {
        Int32(max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 1)))
    }

    func cancel() { abortFlag.pointee = true }

    /// Transcribe 16 kHz mono samples. Returns "" for a take with no speech.
    func transcribe(_ samples: [Float], language: String, prompt: String?, vadModel: URL?) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                abortFlag.pointee = false
                guard let ctx else { cont.resume(returning: ""); return }
                var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                p.n_threads = Self.threadCount
                p.print_progress = false
                p.print_realtime = false
                p.print_special = false
                p.print_timestamps = false
                p.translate = false
                p.no_context = true
                p.suppress_nst = true
                p.detect_language = false

                let lang = modelName.hasSuffix(".en") ? "en" : language

                let rc: Int32 = lang.withCString { langC in
                    (prompt ?? "").withCString { promptC in
                        (vadModel?.path ?? "").withCString { vadC in
                            p.language = langC
                            if prompt != nil { p.initial_prompt = promptC }
                            if vadModel != nil {
                                p.vad = true
                                p.vad_model_path = vadC
                                p.vad_params = whisper_vad_default_params()
                            }
                            p.abort_callback = { data in
                                data?.assumingMemoryBound(to: Bool.self).pointee ?? false
                            }
                            p.abort_callback_user_data = UnsafeMutableRawPointer(abortFlag)
                            return samples.withUnsafeBufferPointer { buf in
                                whisper_full(ctx, p, buf.baseAddress, Int32(buf.count))
                            }
                        }
                    }
                }
                if abortFlag.pointee {
                    cont.resume(throwing: CancellationError()); return
                }
                guard rc == 0 else {
                    cont.resume(throwing: NSError(domain: "Tiro", code: 3, userInfo: [NSLocalizedDescriptionKey: "Transcription failed (\(rc))."]))
                    return
                }
                var text = ""
                for i in 0..<whisper_full_n_segments(ctx) {
                    if let seg = whisper_full_get_segment_text(ctx, i) {
                        text += String(cString: seg)
                    }
                }
                cont.resume(returning: NonSpeech.collapse(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}

/// whisper.cpp writes markers like `[BLANK_AUDIO]` or `(music)` for takes
/// with no speech. A take made only of those is empty (same list and rule as
/// the desktop's `collapse_non_speech`). Markers mixed with words stay.
enum NonSpeech {
    static let phrases: Set<String> = [
        "blank audio", "silence", "silent", "inaudible", "music", "music playing",
        "background music", "background noise", "noise", "static", "applause",
        "laughter", "laughing", "laughs", "no speech", "no audio", "breathing",
        "coughing", "cough", "sigh", "sighs", "sighing", "chatter",
        "indistinct chatter", "wind", "typing", "clicking", "humming", "beep",
        "beeping", "pause",
    ]

    static func collapse(_ text: String) -> String {
        var rest = Substring(text).drop(while: { $0.isWhitespace })
        while let first = rest.first {
            if first == "♪" { rest = rest.dropFirst().drop(while: { $0.isWhitespace }); continue }
            let close: Character
            switch first {
            case "[": close = "]"
            case "(": close = ")"
            case "*": close = "*"
            default: return text
            }
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: close) else { return text }
            let inner = body[..<end].lowercased()
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            guard phrases.contains(SmartFormatter.collapseWhitespace(inner)) else { return text }
            rest = body[body.index(after: end)...].drop(while: { $0.isWhitespace })
        }
        return ""
    }
}
