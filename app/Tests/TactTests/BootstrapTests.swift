import Foundation
import Testing
@testable import Tact

struct BootstrapTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-\(UUID().uuidString)")
        var resources: URL { root.appendingPathComponent("Resources") }
        var state: URL { root.appendingPathComponent("state") }
        var config: String { state.appendingPathComponent("config.json").path }

        init() throws {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try "偏好示例".write(to: resources.appendingPathComponent("style.example.md"), atomically: true, encoding: .utf8)
        }

        func bootstrap() {
            AppConfig.bootstrapIfNeeded(configPath: config, resources: resources, stateDirectory: state.path, log: { _ in })
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func firstLaunchStartsWithNoChatTools() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.bootstrap()
        let file = try ConfigFile.load(from: fixture.config)
        let instances = try #require(file.value("platforms") as? [[String: Any]])
        #expect(instances.isEmpty)
        #expect(file.value("adapter") == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.state.appendingPathComponent("style.md").path))
        #expect(PlatformRegistry(file: file, configPath: fixture.config).registrations.isEmpty)
    }

    @Test(arguments: [
        ["platforms": [["id": "custom-1", "manifest": "/plugins/a/manifest.json", "enabled": true]]],
        ["adapter": ["command": ["python3", "/custom/my_im.py"]], "unknown": true],
        ["platforms": [], "app": ["hotkey": "double+option"]],
    ] as [[String: Any]])
    func anExistingConfigIsNeverTouched(root: [String: Any]) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try ConfigFile(root: root).write(to: fixture.config)
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.config))
        fixture.bootstrap()
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.config)) == before)
    }
}
