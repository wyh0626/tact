import Foundation
import Testing
@testable import Tact

struct PlatformTests {
    @Test func loadsStandardManifest() throws {
        try withManifest { _, manifestURL in
            let manifest = try PlatformManifest.load(at: manifestURL.path)
            #expect(manifest.id == "test.chat")
            #expect(manifest.protocolVersion == 1)
            #expect(manifest.transport == "command-v1")
            #expect(manifest.entrypoint == ["/usr/bin/python3", "${plugin_dir}/adapter.py"])
            #expect(manifest.capabilities["conversations.list"] == true)
            #expect(manifest.capabilities["messages.read"] == true)
            #expect(manifest.desktop.bundleIDs == ["test.chat.desktop"])
        }
    }

    @Test func rejectsUnknownProtocolOrTransport() throws {
        for change: [String: Any] in [["protocol_version": 2], ["transport": "json-rpc-stdio"]] {
            try withManifest(changes: change) { _, manifestURL in
                #expect(throws: PlatformError.self) {
                    try PlatformManifest.load(at: manifestURL.path)
                }
            }
        }
    }

    @Test func requiresConversationAndMessageCapabilities() throws {
        let invalidCapabilities: [[String: Bool]] = [
            ["messages.read": true],
            ["conversations.list": true],
            ["conversations.list": false, "messages.read": true],
            ["conversations.list": true, "messages.read": false],
        ]
        for capabilities in invalidCapabilities {
            try withManifest(changes: ["capabilities": capabilities]) { _, manifestURL in
                #expect(throws: PlatformError.self) {
                    try PlatformManifest.load(at: manifestURL.path)
                }
            }
        }
    }

    @Test func commandTransportRejectsRealtimeEventCapability() throws {
        try withManifest(changes: ["capabilities": ["conversations.list": true, "messages.read": true, "events.subscribe": true]]) { _, manifestURL in
            #expect(throws: PlatformError.self) {
                try PlatformManifest.load(at: manifestURL.path)
            }
        }
    }

    @Test func rejectsNonpositiveTimeoutAndNegativeCacheLimit() throws {
        for limits in [["timeout_ms": 0, "chats_cache_seconds": 300],
                       ["timeout_ms": -1, "chats_cache_seconds": 300],
                       ["timeout_ms": 15000, "chats_cache_seconds": -1]] {
            try withManifest(changes: ["limits": limits]) { _, manifestURL in
                #expect(throws: PlatformError.self) {
                    try PlatformManifest.load(at: manifestURL.path)
                }
            }
        }
    }

    /// Chat tools come only from imported plugins; an old adapter section
    /// registers nothing.
    @Test func aConfigWithoutPlatformsHasNoChatTools() {
        let registry = PlatformRegistry(file: ConfigFile(root: [
            "adapter": ["command": ["python3", "/old/adapter.py"]], "app": ["target_bundle_id": "com.example.chat"]
        ]))
        #expect(registry.registrations.isEmpty)
        #expect(registry.match(bundleID: "com.example.chat") == nil)
    }

    @Test func malformedPlatformListIsReportedAndMatchesNothing() {
        let file = ConfigFile(root: ["platforms": "invalid"])
        let registry = PlatformRegistry(file: file)
        #expect(registry.registrations.count == 1)
        #expect(registry.registrations.first?.error != nil)
        #expect(registry.match(bundleID: "com.example.chat") == nil)
    }

    @Test func disabledPlatformCannotMatchForegroundApplication() throws {
        try withManifest { configURL, manifestURL in
            let registry = PlatformRegistry(file: ConfigFile(root: ["platforms": [
                instance(id: "disabled", manifest: manifestURL.path, enabled: false),
            ]]), configPath: configURL.path)
            #expect(registry.registrations.first?.available == true)
            #expect(registry.match(bundleID: "test.chat.desktop") == nil)
            #expect(registry.match(bundleID: nil) == nil)
        }
    }

    @Test func ambiguousForegroundApplicationFailsClosed() throws {
        try withManifest { configURL, manifestURL in
            let registry = PlatformRegistry(file: ConfigFile(root: ["platforms": [
                instance(id: "account-one", manifest: manifestURL.path),
                instance(id: "account-two", manifest: manifestURL.path),
            ]]), configPath: configURL.path)
            #expect(registry.registrations.allSatisfy { $0.available })
            #expect(registry.match(bundleID: "test.chat.desktop") == nil)

            let unambiguous = PlatformRegistry(file: ConfigFile(root: ["platforms": [
                instance(id: "account-one", manifest: manifestURL.path),
                instance(id: "account-two", manifest: manifestURL.path, enabled: false),
            ]]), configPath: configURL.path)
            #expect(unambiguous.match(bundleID: "test.chat.desktop")?.id == "account-one")
        }
    }

    @Test func everyRegistrationWithDuplicateInstanceIDIsInvalid() throws {
        try withManifest { configURL, manifestURL in
            let registry = PlatformRegistry(file: ConfigFile(root: ["platforms": [
                instance(id: "duplicate", manifest: manifestURL.path),
                instance(id: "duplicate", manifest: manifestURL.path, enabled: false),
            ]]), configPath: configURL.path)
            #expect(registry.registrations.count == 2)
            #expect(registry.registrations.allSatisfy { !$0.available && $0.error != nil })
            #expect(registry.match(bundleID: "test.chat.desktop") == nil)
        }
    }

    @Test func desktopOverridesMergeWithoutDroppingPluginDefaults() throws {
        try withManifest { configURL, manifestURL in
            var entry = instance(id: "custom", manifest: manifestURL.path)
            entry["desktop"] = [
                "bundle_ids": ["company.custom"],
                "header": ["top_offset": 44],
                "overlay": ["offset_y": 9],
                "send_shortcut": "command+return",
            ]
            let registry = PlatformRegistry(file: ConfigFile(root: ["platforms": [entry]]), configPath: configURL.path)
            let registration = try #require(registry.match(bundleID: "company.custom"))
            #expect(registry.match(bundleID: "test.chat.desktop") == nil)
            #expect(registration.desktop?.header.topOffset == 44)
            #expect(registration.desktop?.header.height == 64)
            #expect(registration.desktop?.header.leftPadding == 0)
            #expect(registration.desktop?.overlay.fontSize == 13)
            #expect(registration.desktop?.overlay.offsetY == 9)
            #expect(registration.desktop?.sendShortcut == "command+return")

            var original = AppConfig()
            original.socketPath = "/tmp/test-engine.sock"
            original.hotkey = "ctrl+option+space"
            let runtime = registration.runtimeConfig(from: original)
            #expect(runtime.headerTopOffset == 44)
            #expect(runtime.headerHeight == 64)
            #expect(runtime.ghostOffsetY == 9)
            #expect(runtime.socketPath == original.socketPath)
            #expect(runtime.hotkey == original.hotkey)
        }
    }

    @Test func relativeManifestPathResolvesAgainstConfigDirectory() throws {
        try withManifest { configURL, manifestURL in
            let registry = PlatformRegistry(file: ConfigFile(root: ["platforms": [
                instance(id: "relative", manifest: "plugins/fixture/manifest.json"),
            ]]), configPath: configURL.path)
            let registration = try #require(registry.match(bundleID: "test.chat.desktop"))
            #expect(registration.manifestPath == manifestURL.path)
            #expect(registration.manifest?.name == "Test Chat")
        }
    }

    @Test func loadingRegistryDoesNotExecutePlugin() throws {
        try withManifest { configURL, manifestURL in
            let marker = configURL.deletingLastPathComponent().appendingPathComponent("plugin-executed")
            var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            raw["entrypoint"] = ["/usr/bin/touch", marker.path]
            try JSONSerialization.data(withJSONObject: raw).write(to: manifestURL)
            let registry = PlatformRegistry(file: ConfigFile(root: ["platforms": [
                instance(id: "read-only", manifest: manifestURL.path),
            ]]), configPath: configURL.path)
            #expect(registry.match(bundleID: "test.chat.desktop") != nil)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    private func instance(id: String, manifest: String, enabled: Bool = true) -> [String: Any] {
        ["id": id, "manifest": manifest, "enabled": enabled]
    }

    private func withManifest(changes: [String: Any] = [:], _ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("platform-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("plugins/fixture/manifest.json")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "protocol_version": 1, "id": "test.chat", "name": "Test Chat", "version": "1.0.0",
            "transport": "command-v1", "entrypoint": ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
            "capabilities": ["conversations.list": true, "messages.read": true, "composer.apply": true],
            "desktop": [
                "strategy": "ax-ocr-v1", "bundle_ids": ["test.chat.desktop"],
                "header": ["top_offset": 28, "height": 64, "left_padding": 0],
                "overlay": ["font_size": 13, "offset_x": 0, "offset_y": 0],
                "send_shortcut": "return",
            ],
        ]
        manifest.merge(changes) { _, changed in changed }
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        try body(directory.appendingPathComponent("config.json"), manifestURL)
    }
}
