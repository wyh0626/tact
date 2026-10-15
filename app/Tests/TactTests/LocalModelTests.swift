import CryptoKit
import Foundation
import Testing
@testable import Tact

@MainActor
@Suite(.serialized)
struct LocalModelTests {
    @Test func recommendationFollowsMemory() {
        #expect(LocalModel.recommended(forMemoryGB: 4).id == "qwen3-1.7b")
        #expect(LocalModel.recommended(forMemoryGB: 8).id == "qwen3-1.7b")
        #expect(LocalModel.recommended(forMemoryGB: 16).id == "qwen3-4b-instruct")
        #expect(LocalModel.recommended(forMemoryGB: 24).id == "qwen3-8b")
        #expect(LocalModel.recommended(forMemoryGB: 64).id == "qwen3-8b")
    }

    @Test func catalogEntriesAreComplete() {
        for model in LocalModel.catalog {
            #expect(model.sha256.count == 64 && model.sha256.allSatisfy(\.isHexDigit))
            #expect(model.bytes > 500_000_000 && model.file.hasSuffix(".gguf"))
            #expect(model.minimumMemoryGB <= model.recommendedMemoryGB)
        }
        let store = LocalModelStore(directory: FileManager.default.temporaryDirectory)
        let sources = store.sources(for: LocalModel.catalog[0])
        #expect(sources.map(\.host) == ["huggingface.co", "hf-mirror.com"])
        #expect(sources[0].path == "/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")
    }

    @Test func downloadVerifiesAndInstalls() async throws {
        try await withServer { server, models in
            let payload = Data("a tiny model".utf8)
            let model = try server.publish(payload, file: "tiny.gguf")
            let store = LocalModelStore(directory: models, hosts: [server.base])
            store.download(model)
            let state = await settle(store, model)
            #expect(state == .ready)
            #expect(try Data(contentsOf: store.url(for: model)) == payload)
            #expect(store.isReady(model))
        }
    }

    @Test func aSourceThatFailsFallsBackToTheNext() async throws {
        try await withServer { server, models in
            let model = try server.publish(Data("from the mirror".utf8), file: "mirrored.gguf")
            let store = LocalModelStore(directory: models, hosts: [server.base + "/missing", server.base])
            store.download(model)
            #expect(await settle(store, model) == .ready)
        }
    }

    @Test func aFileThatFailsItsChecksumIsThrownAway() async throws {
        try await withServer { server, models in
            var model = try server.publish(Data("tampered".utf8), file: "bad.gguf")
            model = LocalModel(id: model.id, name: model.name, repository: model.repository, file: model.file,
                               bytes: model.bytes, sha256: String(repeating: "0", count: 64),
                               minimumMemoryGB: 1, recommendedMemoryGB: 1, thinks: false)
            let store = LocalModelStore(directory: models, hosts: [server.base])
            store.download(model)
            guard case .failed(let reason) = await settle(store, model) else {
                Issue.record("expected a failed download")
                return
            }
            #expect(reason.contains(L10n.tr("校验", "verification")))
            #expect(!FileManager.default.fileExists(atPath: store.url(for: model).path))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: models.path)
            #expect(leftovers.isEmpty, "nothing half-downloaded stays behind: \(leftovers)")
        }
    }

    @Test func filesOnDiskDecideTheStateAndDeleteClearsThem() throws {
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("tact-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: models) }
        let small = LocalModel.catalog[0]
        // A file of the wrong size is not a model.
        try Data("partial".utf8).write(to: models.appendingPathComponent(small.file))
        let store = LocalModelStore(directory: models)
        #expect(store.state(of: small) == .absent)
        // A saved resume point shows as paused.
        try Data("resume".utf8).write(to: models.appendingPathComponent(small.file + ".resume"))
        store.refresh()
        #expect(store.state(of: small) == .paused(0))
        store.delete(small)
        #expect(store.state(of: small) == .absent)
        #expect(try FileManager.default.contentsOfDirectory(atPath: models.path).isEmpty)
    }

    @Test func notEnoughDiskIsSaidUpFront() {
        let store = LocalModelStore(directory: FileManager.default.temporaryDirectory)
        let huge = LocalModel(id: "huge", name: "Huge", repository: "r", file: "h.gguf", bytes: Int64.max / 4,
                              sha256: "", minimumMemoryGB: 1, recommendedMemoryGB: 1, thinks: false)
        #expect(store.spaceProblem(for: huge)?.contains(L10n.tr("磁盘空间不够", "Not enough disk space")) == true)
        store.download(huge)
        guard case .failed = store.state(of: huge) else {
            Issue.record("a download that cannot fit must not start")
            return
        }
    }

    @Test func savingALocalModelWritesItsFileAndTurnsThinkingOff() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("tact-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: models) }
        let store = LocalModelStore(directory: models)
        var file = ConfigFile(root: ["model": ["base_url": "https://api.deepseek.com/v1", "model": "deepseek-flash",
                                               "extra_body": ["thinking": ["type": "disabled"]]]])
        let settings = ModelSettings(file: file, localStore: store)
        settings.choose(.local)
        let thinker = LocalModel.catalog[0]
        settings.useLocalModel(thinker)
        #expect(settings.validationError == L10n.tr("先下载 \(thinker.name)", "Download \(thinker.name) first"))
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let handle = try FileHandle(forWritingTo: { let u = store.url(for: thinker); FileManager.default.createFile(atPath: u.path, contents: nil); return u }())
        try handle.truncate(atOffset: UInt64(thinker.bytes))
        try handle.close()
        store.refresh()
        #expect(settings.validationError == nil)

        settings.write(into: &file)
        #expect(file.string("model.provider") == "local")
        #expect(file.string("model.model") == thinker.id)
        #expect(file.string("model.local.path") == store.url(for: thinker).path)
        #expect(file.value("model.extra_body.chat_template_kwargs.enable_thinking") as? Bool == false)
        #expect(file.value("model.extra_body.thinking") == nil)
        #expect(settings.summary == L10n.tr("本机 · Qwen3 1.7B", "Local · Qwen3 1.7B"))
        // Reading the config back finds the same model.
        #expect(ModelSettings(file: file, localStore: store).localModelID == thinker.id)
        #expect(ModelSettings(file: file, localStore: store).provider == .local)

        settings.choose(.deepseek)
        #expect(settings.model == "deepseek-flash")
        settings.write(into: &file)
        #expect(file.value("model.local") == nil && file.value("model.extra_body.chat_template_kwargs") == nil)
        #expect(file.string("model.provider") == "deepseek")
    }

    @Test func choosingLocalUsesADownloadedModelOrPicksTheRecommendedOne() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let models = FileManager.default.temporaryDirectory.appendingPathComponent("tact-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: models) }
        // Nothing listens on port 9: a download that starts goes nowhere.
        let store = LocalModelStore(directory: models, hosts: ["http://127.0.0.1:9"])
        let cloud = ConfigFile(root: ["model": ["base_url": "https://api.deepseek.com/v1", "model": "deepseek-flash"]])

        let empty = ModelSettings(file: cloud, localStore: store)
        empty.chooseCard(.local)
        let recommended = LocalModel.recommended(forMemoryGB: LocalModelStore.memoryGB)
        #expect(empty.localModelID == recommended.id)
        #expect(LocalModel.catalog.allSatisfy { store.state(of: $0) == .absent }, "nothing downloads until asked")

        // One already on disk is used, and nothing else is fetched.
        let small = LocalModel.catalog[0]
        FileManager.default.createFile(atPath: store.url(for: small).path, contents: nil)
        let handle = try FileHandle(forWritingTo: store.url(for: small))
        try handle.truncate(atOffset: UInt64(small.bytes))
        try handle.close()
        store.refresh()
        let withModel = ModelSettings(file: cloud, localStore: store)
        withModel.chooseCard(.local)
        #expect(!store.isReady(recommended))
        #expect(withModel.localModelID == small.id, "the model already on disk is used")
        #expect(LocalModel.catalog.allSatisfy { store.state(of: $0) == .ready || store.state(of: $0) == .absent })
        #expect(withModel.savedLocalModelID == nil, "chosen is not saved until it is")
    }

    @Test func theSavedLocalModelIsReadFromTheConfig() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let store = LocalModelStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString)"))
        let saved = ConfigFile(root: ["model": ["provider": "local", "model": "qwen3-8b",
                                                "local": ["path": "/x/models/Qwen3-8B-Q4_K_M.gguf"]]])
        #expect(ModelSettings(file: saved, localStore: store).savedLocalModelID == "qwen3-8b")
        let cloud = ConfigFile(root: ["model": ["provider": "", "local": ["path": "/x/models/Qwen3-8B-Q4_K_M.gguf"]]])
        #expect(ModelSettings(file: cloud, localStore: store).savedLocalModelID == nil)
    }

    // MARK: - A local web server for downloads

    private struct Server {
        let base: String
        let root: URL

        /// Serves `data` the way Hugging Face lays files out, and returns a
        /// model entry that matches it.
        func publish(_ data: Data, file: String) throws -> LocalModel {
            let folder = root.appendingPathComponent("tests/tiny/resolve/main", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(file))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return LocalModel(id: "test-" + file, name: "Test", repository: "tests/tiny", file: file,
                              bytes: Int64(data.count), sha256: digest, minimumMemoryGB: 1, recommendedMemoryGB: 1, thinks: false)
        }
    }

    private func withServer(_ body: (Server, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tact-dl-\(UUID().uuidString)")
        let root = base.appendingPathComponent("www"), models = base.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let port = Int.random(in: 41_000...48_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let server = Server(base: "http://127.0.0.1:\(port)", root: root)
        for _ in 0..<100 {
            if (try? Data(contentsOf: URL(string: server.base + "/")!)) != nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await body(server, models)
    }

    private func settle(_ store: LocalModelStore, _ model: LocalModel) async -> LocalModelStore.State {
        for _ in 0..<200 {
            switch store.state(of: model) {
            case .ready, .failed: return store.state(of: model)
            default: try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return store.state(of: model)
    }
}
