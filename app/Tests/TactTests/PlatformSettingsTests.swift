import Foundation
import Testing
@testable import Tact

@MainActor
struct PlatformSettingsTests {
    @Test func emptyRegistryListsNothing() async throws {
        try await withFixture { settings, _, _, _ in
            #expect(settings.entries.isEmpty)
            #expect(settings.selectedID == nil)
        }
    }

    @Test func aPluginAppearsOnlyAfterItsPackageIsImported() async throws {
        try await withFixture { settings, configURL, _, _ in
            #expect(!settings.entries.contains { $0.name == ExamplePlugin.name })
            await settings.importPlugin(from: ExamplePlugin.folder)
            #expect(settings.problem == nil)
            let example = try #require(settings.entries.first { $0.name == ExamplePlugin.name })
            #expect(example.supported && !example.enabled)
            #expect(example.removable)
            #expect(example.version == ExamplePlugin.version)
            #expect(!settings.selectedConnectionVerified)
            let saved = try ConfigFile.load(from: configURL.path)
            let instances = try #require(saved.value("platforms") as? [[String: Any]])
            #expect(instances.first?["origin"] as? String == "imported")
        }
    }

    @Test func importingCopiesPluginAndRegistersItDisabled() async throws {
        try await withFixture { settings, configURL, source, marker in
            await settings.importPlugin(from: source)

            #expect(settings.problem == nil)
            #expect(!settings.busy)
            let selected = try #require(settings.selected)
            #expect(selected.name == "Company Chat")
            #expect(selected.supported)
            #expect(!selected.enabled)
            #expect(selected.removable)
            #expect(selected.status.contains(L10n.tr("未启用", "Disabled")) && selected.tone == .neutral)
            #expect(selected.capabilityLabels.contains(L10n.tr("消息读取", "Read messages")))

            let saved = try ConfigFile.load(from: configURL.path)
            let instances = try #require(saved.value("platforms") as? [[String: Any]])
            #expect(instances.count == 1)
            #expect(instances[0]["enabled"] as? Bool == false)
            #expect(instances[0]["id"] as? String == selected.id)
            #expect(saved.string("unrelated.setting") == "preserved")
            let manifestPath = try #require(instances[0]["manifest"] as? String)
            let package = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
            #expect(package.deletingLastPathComponent().path == configURL.deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true).path)
            #expect(package != source)
            let copiedScript = try Data(contentsOf: package.appendingPathComponent("adapter.py"))
            let originalScript = try Data(contentsOf: source.appendingPathComponent("adapter.py"))
            #expect(copiedScript == originalScript)
            #expect(!FileManager.default.fileExists(atPath: marker.path), "Import must not start the plugin command")
        }
    }

    @Test func selectingAnUnknownPlatformKeepsTheSelectionAndDoesNotWrite() async throws {
        try await withFixture { settings, configURL, source, _ in
            await settings.importPlugin(from: source)
            let imported = try #require(settings.selectedID)
            let original = try Data(contentsOf: configURL)
            for id in ["wechat", "unsupported-wechat", ""] {
                settings.select(id)
                #expect(settings.selectedID == imported)
            }
            #expect(try Data(contentsOf: configURL) == original)
            #expect(settings.problem == nil)
        }
    }

    @Test func languageRefreshAndRepeatedSelectionPreserveUnsavedCalibration() async throws {
        try await L10n.$overrideLanguage.withValue(.simplifiedChinese) {
            try await withFixture { settings, configURL, source, marker in
                await settings.importPlugin(from: source)
                let firstID = try #require(settings.selectedID)
                await settings.importPlugin(from: source)
                let selectedID = try #require(settings.selectedID)
                #expect(selectedID != firstID)
                let original = try Data(contentsOf: configURL)
                settings.prepareToolList()
                #expect(settings.expandedToolID == selectedID)

                settings.targetBundleID = "test.unsaved.desktop"
                settings.headerTopOffset = 42
                settings.headerHeight = 88
                settings.select(selectedID)
                L10n.$overrideLanguage.withValue(.english) {
                    NotificationCenter.default.post(name: .tactLanguageDidChange, object: nil)
                    // LocalizedContent recreates the list and calls onAppear.
                    settings.prepareToolList()
                    settings.select(selectedID)
                    #expect(settings.selected?.capabilityLabels.contains("Read messages") == true)
                    #expect(settings.selected?.status.contains("Disabled") == true)
                }

                #expect(settings.selectedID == selectedID)
                #expect(settings.expandedToolID == selectedID)
                #expect(settings.targetBundleID == "test.unsaved.desktop")
                #expect(settings.headerTopOffset == 42)
                #expect(settings.headerHeight == 88)
                // A deliberate collapse also survives view recreation.
                settings.expandedToolID = nil
                settings.prepareToolList()
                #expect(settings.expandedToolID == nil)
                #expect(try Data(contentsOf: configURL) == original)
                #expect(!FileManager.default.fileExists(atPath: marker.path))
            }
        }
    }

    @Test func invalidManifestDoesNotChangeConfigurationOrSelection() async throws {
        try await withFixture(manifestChanges: ["protocol_version": 2]) { settings, configURL, source, marker in
            let original = try Data(contentsOf: configURL)
            let selection = settings.selectedID
            await settings.importPlugin(from: source)
            #expect(settings.problem?.contains(L10n.tr("导入失败", "Import failed")) == true)
            #expect(!settings.busy)
            #expect(settings.selectedID == selection)
            #expect(try Data(contentsOf: configURL) == original)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(!FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().appendingPathComponent("plugins").path))
        }
    }

    @Test func missingPackageDoesNotChangeConfiguration() async throws {
        try await withFixture { settings, configURL, source, marker in
            let original = try Data(contentsOf: configURL)
            await settings.importPlugin(from: source.appendingPathComponent("missing"))
            #expect(settings.problem != nil)
            #expect(!settings.busy)
            #expect(try Data(contentsOf: configURL) == original)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func busyImportIsIgnoredWithoutChangingConfiguration() async throws {
        try await withFixture { settings, configURL, source, marker in
            let original = try Data(contentsOf: configURL)
            let selection = settings.selectedID
            settings.busy = true
            await settings.importPlugin(from: source)
            #expect(settings.busy)
            #expect(settings.selectedID == selection)
            #expect(settings.problem == nil)
            #expect(try Data(contentsOf: configURL) == original)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            settings.busy = false
        }
    }

    @Test func repeatedImportsCreateIndependentDisabledInstances() async throws {
        try await withFixture { settings, configURL, source, marker in
            await settings.importPlugin(from: source)
            let firstID = try #require(settings.selectedID)
            await settings.importPlugin(from: source)
            let secondID = try #require(settings.selectedID)
            #expect(settings.problem == nil)
            #expect(firstID != secondID)
            let imported = settings.entries.filter { $0.name == "Company Chat" }
            #expect(imported.count == 2)
            #expect(imported.allSatisfy { $0.supported && !$0.enabled })
            let saved = try ConfigFile.load(from: configURL.path)
            let instances = try #require(saved.value("platforms") as? [[String: Any]])
            #expect(instances.count == 2)
            let manifests = instances.compactMap { $0["manifest"] as? String }
            #expect(Set(manifests).count == 2)
            #expect(manifests.allSatisfy { FileManager.default.fileExists(atPath: $0) })
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func maximumLengthManifestIDCanBeImported() async throws {
        try await withFixture(manifestChanges: ["id": String(repeating: "a", count: 128)]) { settings, configURL, source, _ in
            await settings.importPlugin(from: source)
            #expect(settings.problem == nil)
            let selected = try #require(settings.selected)
            #expect(selected.supported && !selected.enabled)
            #expect(PlatformManifest.validID(selected.id))
            let registry = PlatformRegistry(file: try ConfigFile.load(from: configURL.path), configPath: configURL.path)
            #expect(registry.registrations.count == 1)
            #expect(registry.registrations.first?.available == true)
        }
    }

    private func withFixture(manifestChanges: [String: Any] = [:],
                             _ body: (PlatformSettings, URL, URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("platform-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let marker = directory.appendingPathComponent("plugin-executed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "protocol_version": 1, "id": "test.company", "name": "Company Chat", "version": "1.0.0",
            "transport": "command-v1", "entrypoint": ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
            "capabilities": ["conversations.list": true, "messages.read": true, "composer.apply": true],
            "desktop": [
                "strategy": "ax-ocr-v1", "bundle_ids": ["test.company.desktop"],
                "header": ["top_offset": 28, "height": 64, "left_padding": 0],
                "overlay": ["font_size": 13, "offset_x": 0, "offset_y": 0],
                "send_shortcut": "return",
            ],
        ]
        manifest.merge(manifestChanges) { _, changed in changed }
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        let script = "import pathlib\npathlib.Path(\(String(reflecting: marker.path))).touch()\n"
        try script.write(to: source.appendingPathComponent("adapter.py"), atomically: true, encoding: .utf8)
        let file = ConfigFile(root: ["platforms": [], "unrelated": ["setting": "preserved"]])
        try file.write(to: configURL.path)
        var config = AppConfig()
        config.socketPath = directory.appendingPathComponent("no-engine.sock").path
        config.engineCommand = ["/usr/bin/false"]
        let settings = PlatformSettings(controller: Controller(config: config), file: file, configPath: configURL.path)
        try await body(settings, configURL, source, marker)
    }
}
