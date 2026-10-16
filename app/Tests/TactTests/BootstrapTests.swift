import CryptoKit
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

    /// A style file still holding a template an earlier version installed
    /// takes the current one; an edited file is left alone.
    @Test func anUneditedDefaultStyleTakesTheNewTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
        let style = fixture.state.appendingPathComponent("style.md")
        let old = Data("- 旧的默认模板".utf8)
        let shipped = [SHA256.hash(data: old).map { String(format: "%02x", $0) }.joined(): "style.example.md"]
        let refresh = { AppConfig.refreshUntouchedStyle(at: style.path, resources: fixture.resources, shipped: shipped, log: { _ in }) }

        try old.write(to: style)
        refresh()
        #expect(try String(contentsOf: style, encoding: .utf8) == "偏好示例")

        try Data("- 旧的默认模板\n- 我自己加的一条".utf8).write(to: style)
        refresh()
        #expect(try String(contentsOf: style, encoding: .utf8).contains("我自己加的一条"), "an edited file is never replaced")
    }

    /// The shipped list names templates the app bundles, and never the
    /// current ones, which would replace themselves on every launch.
    @Test func shippedStylesPointAtBundledTemplates() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in Set(AppConfig.shippedStyles.values) {
            let current = try Data(contentsOf: repo.appendingPathComponent(name))
            let digest = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
            #expect(AppConfig.shippedStyles[digest] == nil, "\(name) as it is now must not be listed")
        }
    }
}
