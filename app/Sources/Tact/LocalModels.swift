import CryptoKit
import Foundation

/// A model Tact can download and run on this Mac with the llama-server
/// inside the app.
struct LocalModel: Identifiable, Hashable {
    let id: String
    let name: String
    let repository: String
    let file: String
    let bytes: Int64
    let sha256: String
    /// Below this the Mac runs short of memory.
    let minimumMemoryGB: Int
    /// The Mac the model suits best.
    let recommendedMemoryGB: Int
    /// Qwen3's hybrid models think before answering unless told not to,
    /// which a chat reply never needs.
    let thinks: Bool

    static let catalog = [
        LocalModel(id: "qwen3-1.7b", name: "Qwen3 1.7B", repository: "unsloth/Qwen3-1.7B-GGUF",
                   file: "Qwen3-1.7B-Q4_K_M.gguf", bytes: 1_107_409_472,
                   sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
                   minimumMemoryGB: 8, recommendedMemoryGB: 8, thinks: true),
        LocalModel(id: "qwen3-4b-instruct", name: "Qwen3 4B", repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
                   file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", bytes: 2_497_281_120,
                   sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
                   minimumMemoryGB: 8, recommendedMemoryGB: 16, thinks: false),
        LocalModel(id: "qwen3-8b", name: "Qwen3 8B", repository: "Qwen/Qwen3-8B-GGUF",
                   file: "Qwen3-8B-Q4_K_M.gguf", bytes: 5_027_783_488,
                   sha256: "d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785",
                   minimumMemoryGB: 16, recommendedMemoryGB: 24, thinks: true),
    ]

    static func named(_ id: String) -> LocalModel? { catalog.first { $0.id == id } }

    /// The largest model this Mac runs comfortably.
    static func recommended(forMemoryGB memory: Int) -> LocalModel {
        catalog.last { $0.recommendedMemoryGB <= memory } ?? catalog[0]
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Downloads, checks and removes local models, kept in ~/.tact/models. One
/// store serves the whole app, so a download carries on with the settings
/// window closed.
@MainActor
final class LocalModelStore: NSObject, ObservableObject {
    enum State: Equatable {
        case absent
        case downloading(Double)
        case paused(Double)
        case verifying
        case ready
        case failed(String)
    }

    static let shared = LocalModelStore(directory: URL(fileURLWithPath: AppConfig.directory)
        .appendingPathComponent("models", isDirectory: true))

    nonisolated let directory: URL
    /// Hugging Face first, then a mirror for networks that can't reach it.
    /// Every download is checked against the model's checksum, so a source
    /// does not need to be trusted.
    let hosts: [String]
    @Published private(set) var states: [String: State] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// The models being downloaded, by id, for the session's callbacks.
    private var active: [String: LocalModel] = [:]
    private var sourceIndex: [String: Int] = [:]
    /// Downloads the user paused, so their end is not taken for a failure.
    private var pausing = Set<String>()

    static var memoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }

    init(directory: URL, hosts: [String] = ["https://huggingface.co", "https://hf-mirror.com"]) {
        self.directory = directory
        self.hosts = hosts
        super.init()
        refresh()
    }

    func sources(for model: LocalModel) -> [URL] {
        hosts.compactMap { URL(string: "\($0)/\(model.repository)/resolve/main/\(model.file)") }
    }

    func url(for model: LocalModel) -> URL { directory.appendingPathComponent(model.file) }
    func state(of model: LocalModel) -> State { states[model.id] ?? .absent }
    func isReady(_ model: LocalModel) -> Bool { state(of: model) == .ready }

    private func resumeURL(for file: String) -> URL { directory.appendingPathComponent(file + ".resume") }
    nonisolated private func downloadedURL(forID id: String) -> URL { directory.appendingPathComponent(id + ".download") }

    /// A model is ready when its file is there at its full size; the
    /// checksum was verified when it arrived.
    func refresh() {
        for model in LocalModel.catalog where tasks[model.id] == nil {
            let size = (try? FileManager.default.attributesOfItem(atPath: url(for: model).path)[.size] as? NSNumber)?.int64Value
            if size == model.bytes {
                states[model.id] = .ready
            } else if FileManager.default.fileExists(atPath: resumeURL(for: model.file).path) {
                if case .paused = state(of: model) { continue }
                states[model.id] = .paused(0)
            } else if case .failed = state(of: model) {
                continue
            } else {
                states[model.id] = .absent
            }
        }
    }

    /// Room for the file plus a margin, or the reason there isn't.
    func spaceProblem(for model: LocalModel) -> String? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage else { return nil }
        let needed = model.bytes + 512 * 1_048_576
        guard free < needed else { return nil }
        return L10n.tr("磁盘空间不够：需要 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))，", "Not enough disk space: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed, ")
            + L10n.tr("还剩 \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))", "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) available")
    }

    func download(_ model: LocalModel) {
        guard tasks[model.id] == nil else { return }
        if let problem = spaceProblem(for: model) {
            states[model.id] = .failed(problem)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            states[model.id] = .failed(L10n.tr("建不了模型文件夹：\(error.localizedDescription)", "Could not create the model folder: \(error.localizedDescription)"))
            return
        }
        let resumeFile = resumeURL(for: model.file)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile) {
            try? FileManager.default.removeItem(at: resumeFile)
            task = session.downloadTask(withResumeData: data)
        } else {
            let sources = sources(for: model)
            task = session.downloadTask(with: sources[min(sourceIndex[model.id] ?? 0, sources.count - 1)])
        }
        task.taskDescription = model.id
        tasks[model.id] = task
        active[model.id] = model
        if case .paused(let done) = state(of: model) {
            states[model.id] = .downloading(done)
        } else {
            states[model.id] = .downloading(0)
        }
        task.resume()
    }

    /// Stops a download and keeps what arrived, so it can carry on later,
    /// even after the app quits.
    func pause(_ model: LocalModel) {
        guard let task = tasks[model.id] else { return }
        pausing.insert(model.id)
        let resumeFile = resumeURL(for: model.file)
        task.cancel { data in
            if let data { try? data.write(to: resumeFile, options: .atomic) }
        }
        if case .downloading(let done) = state(of: model) { states[model.id] = .paused(done) }
    }

    func delete(_ model: LocalModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        for file in [url(for: model), resumeURL(for: model.file), downloadedURL(forID: model.id)] {
            try? FileManager.default.removeItem(at: file)
        }
        states[model.id] = .absent
    }

    /// Checks a downloaded file against the catalog and moves it into place.
    func install(_ downloaded: URL, as model: LocalModel) async {
        states[model.id] = .verifying
        let target = url(for: model)
        let result: Result<Void, Error> = await Task.detached(priority: .utility) {
            Result {
                guard try Self.sha256(of: downloaded) == model.sha256 else {
                    try? FileManager.default.removeItem(at: downloaded)
                    throw CocoaError(.fileReadCorruptFile)
                }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: downloaded, to: target)
            }
        }.value
        switch result {
        case .success: states[model.id] = .ready
        case .failure(let error as CocoaError) where error.code == .fileReadCorruptFile:
            states[model.id] = .failed(L10n.tr("文件校验没通过，可能下载时损坏了，请重新下载", "File verification failed. The download may be corrupted; download it again."))
        case .failure(let error): states[model.id] = .failed(L10n.tr("放不进模型文件夹：\(error.localizedDescription)", "Could not move the file to the model folder: \(error.localizedDescription)"))
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A download ended. Success is handled where the file arrives; the two
    /// callbacks reach the main actor in either order.
    private func finished(_ model: LocalModel, task: URLSessionDownloadTask, error: Error?) {
        guard let error, tasks[model.id] === task else { return }
        tasks[model.id] = nil
        if pausing.remove(model.id) != nil { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let done: Double
        if case .downloading(let fraction) = state(of: model) { done = fraction } else { done = 0 }
        if let resume {
            try? resume.write(to: resumeURL(for: model.file), options: .atomic)
            states[model.id] = .failed(L10n.tr("下载中断了，点继续接着下：\(error.localizedDescription)", "Download interrupted. Click Resume to continue: \(error.localizedDescription)"))
        } else if done == 0, (sourceIndex[model.id] ?? 0) + 1 < sources(for: model).count {
            // Nothing arrived from this source: try the next one.
            sourceIndex[model.id, default: 0] += 1
            download(model)
        } else {
            states[model.id] = .failed(L10n.tr("下载失败：\(error.localizedDescription)", "Download failed: \(error.localizedDescription)"))
        }
    }
}

extension LocalModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            guard self.tasks[id] === downloadTask, let model = self.active[id],
                  case .downloading(let shown) = self.state(of: model) else { return }
            let fraction = min(1, Double(totalBytesWritten) / Double(model.bytes))
            if fraction - shown >= 0.002 || fraction >= 1 { self.states[id] = .downloading(fraction) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // The file at `location` is deleted when this returns: move it now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let destination = downloadedURL(forID: id)
        var moved = false
        if status == 200 || status == 206 {
            try? FileManager.default.removeItem(at: destination)
            moved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        }
        Task { @MainActor in
            guard self.tasks[id] === downloadTask, let model = self.active[id] else { return }
            self.tasks[id] = nil
            if moved {
                await self.install(destination, as: model)
            } else if (self.sourceIndex[id] ?? 0) + 1 < self.sources(for: model).count {
                self.sourceIndex[id, default: 0] += 1
                self.states[id] = .absent
                self.download(model)
            } else {
                self.states[id] = .failed(L10n.tr("下载失败：服务器返回 \(status)", "Download failed: server returned \(status)"))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask, let id = task.taskDescription else { return }
        Task { @MainActor in
            guard let model = self.active[id] else { return }
            self.finished(model, task: downloadTask, error: error)
        }
    }
}
