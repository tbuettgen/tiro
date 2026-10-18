//! The Whisper models Tiro can run on a phone, from the same Hugging Face
//! repo and file names the desktop app uses (q8_0 builds). Downloading a
//! model is the only time Tiro uses the network, and only when you ask.

import Foundation

struct WhisperModel: Identifiable, Hashable {
    let name: String
    let hint: String
    let bytes: Int64
    var id: String { name }
    var fileName: String { "ggml-\(name)-q8_0.bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    var englishOnly: Bool { name.hasSuffix(".en") }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

@MainActor
final class ModelStore: NSObject, ObservableObject {
    nonisolated static let catalog: [WhisperModel] = [
        WhisperModel(name: "tiny.en", hint: "Fastest, lowest accuracy", bytes: 43_550_795),
        WhisperModel(name: "base.en", hint: "Fast and accurate — recommended", bytes: 81_781_811),
        WhisperModel(name: "small.en", hint: "Most accurate, slower", bytes: 264_477_561),
        WhisperModel(name: "tiny", hint: "Fastest, all languages", bytes: 43_537_433),
        WhisperModel(name: "base", hint: "Fast, all languages", bytes: 81_768_585),
        WhisperModel(name: "small", hint: "Most accurate, all languages", bytes: 264_464_607),
    ]

    nonisolated static func model(named name: String) -> WhisperModel? { catalog.first { $0.name == name } }

    @Published private(set) var installed: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    nonisolated static var dir: URL {
        var url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true // re-downloadable, keep it out of iCloud backups
        try? url.setResourceValues(rv)
        return url
    }

    nonisolated static func path(for m: WhisperModel) -> URL { dir.appendingPathComponent(m.fileName) }

    nonisolated static func isInstalled(_ m: WhisperModel) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path(for: m).path)
        return (attrs?[.size] as? Int64) == m.bytes
    }

    /// The bundled Silero VAD model.
    nonisolated static var vadModel: URL? { Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") }

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        installed = Set(Self.catalog.filter(Self.isInstalled).map(\.name))
    }

    func download(_ m: WhisperModel) {
        guard tasks[m.name] == nil else { return }
        lastError = nil
        let task = session.downloadTask(with: m.url)
        task.taskDescription = m.name
        tasks[m.name] = task
        progress[m.name] = 0
        task.resume()
    }

    func cancelDownload(_ m: WhisperModel) {
        tasks[m.name]?.cancel()
        tasks[m.name] = nil
        progress[m.name] = nil
    }

    func delete(_ m: WhisperModel) {
        try? FileManager.default.removeItem(at: Self.path(for: m))
        refresh()
    }
}

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let name = downloadTask.taskDescription, let m = ModelStore.model(named: name) else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : m.bytes
        let frac = Double(totalBytesWritten) / Double(total)
        MainActor.assumeIsolated { self.progress[name] = frac }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let name = downloadTask.taskDescription, let m = ModelStore.model(named: name) else { return }
        // The temp file is deleted when this returns, so move it now.
        let dest = ModelStore.path(for: m)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        var failure: String?
        if status != 200 {
            failure = "Download failed (HTTP \(status))."
        } else {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: location, to: dest) } catch { failure = error.localizedDescription }
            if failure == nil, !ModelStore.isInstalled(m) {
                try? FileManager.default.removeItem(at: dest)
                failure = "The \(m.name) download was incomplete. Try again."
            }
        }
        MainActor.assumeIsolated {
            self.tasks[name] = nil
            self.progress[name] = nil
            if let failure { self.lastError = failure }
            self.refresh()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let name = task.taskDescription else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        MainActor.assumeIsolated {
            self.tasks[name] = nil
            self.progress[name] = nil
            if !cancelled { self.lastError = error.localizedDescription }
        }
    }
}
