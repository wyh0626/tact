import Foundation
import Testing
@testable import Tact

@MainActor
struct ChatToolSetupTests {
    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func developerBriefCarriesValidProtocolExamples(language: AppLanguage) throws {
        try L10n.$overrideLanguage.withValue(language) {
            let text = PluginBrief.text
            #expect(text.contains(L10n.tr("由我自己发送", "I send it myself")))
            #expect(text.contains("docs/ADAPTER.md") && text.contains("plugins/template/"))
            #expect(text.contains("setup.commands"))

            let historyLine = try #require(text.components(separatedBy: .newlines).first { $0.contains(L10n.tr("history 示例：", "history example:")) })
            let historyJSON = try #require(historyLine.components(separatedBy: L10n.tr("history 示例：", "history example:")).last)
            let history = try #require(JSONSerialization.jsonObject(with: Data(historyJSON.utf8)) as? [String: Any])
            let message = try #require((history["messages"] as? [[String: Any]])?.first)
            #expect(message["from_me"] as? Bool == false)
            let time = try #require(message["time"] as? String)
            #expect(ISO8601DateFormatter().date(from: time) != nil)

            let exampleStart = try #require(text.range(of: L10n.tr("manifest.json 示例：", "manifest.json example:")))
            let exampleEnd = try #require(text.range(of: L10n.tr("完整规范见", "See docs/ADAPTER.md")))
            let manifestJSON = String(text[exampleStart.upperBound..<exampleEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let manifest = try JSONDecoder().decode(PlatformManifest.self, from: Data(manifestJSON.utf8))
            try manifest.validate()
            #expect(manifest.capabilities["events.subscribe"] == false)
            let login = try #require(manifest.setup?.commands?.first)
            #expect(login.requiresInput && login.inputPlaceholder != nil)
        }
    }

    @Test func validFolderIsAddedDisabledWithItsSetupAndNothingRuns() async throws {
        try await withFixture { model, settings, configURL, source, marker in
            #expect(await model.importPackage(from: source))
            #expect(settings.problem == nil)
            let entry = try #require(settings.selected)
            #expect(entry.name == "Company Chat")
            #expect(entry.supported && !entry.enabled)
            #expect(entry.status.contains(L10n.tr("未启用", "Disabled")))
            #expect(!settings.selectedConnectionVerified)
            #expect(settings.selectedSetup?.summary == "先完成提供方的登录流程")
            #expect(settings.selectedSetup?.requirements == ["安装公司提供的客户端"])
            #expect(settings.selectedSetup?.steps == ["登录公司账号", "返回 Tact 检测连接"])
            #expect(settings.selectedSetup?.safeHelpURL?.absoluteString == "https://example.com/help")
            #expect(settings.selectedCommand == "/usr/bin/python3 adapter.py")
            #expect(settings.selectedIdentity == "test.company · v1.0.0")
            let file = try ConfigFile.load(from: configURL.path)
            let instances = try #require(file.value("platforms") as? [[String: Any]])
            #expect(instances.count == 1 && instances[0]["enabled"] as? Bool == false)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func zipOfTheFolderImportsLikeTheFolder() async throws {
        try await withFixture { model, settings, configURL, source, marker in
            let archive = source.deletingLastPathComponent().appendingPathComponent("company-chat.zip")
            try zip(source, to: archive)
            #expect(await model.importPackage(from: archive))
            #expect(settings.problem == nil)
            #expect(settings.selected?.name == "Company Chat")
            let file = try ConfigFile.load(from: configURL.path)
            let manifestPath = try #require((file.value("platforms") as? [[String: Any]])?.first?["manifest"] as? String)
            let copied = URL(fileURLWithPath: manifestPath).deletingLastPathComponent()
            #expect(FileManager.default.fileExists(atPath: copied.appendingPathComponent("adapter.py").path))
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func folderHoldingThePluginOneLevelDownIsAccepted() async throws {
        try await withFixture { model, settings, _, source, _ in
            let outer = source.deletingLastPathComponent().appendingPathComponent("download", isDirectory: true)
            try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: outer.appendingPathComponent("company-chat"))
            #expect(await model.importPackage(from: outer))
            #expect(settings.selected?.name == "Company Chat")
        }
    }

    @Test func packageWithoutManifestIsRefusedAndNothingChanges() async throws {
        try await withFixture { model, settings, configURL, source, marker in
            let original = try Data(contentsOf: configURL)
            let empty = source.deletingLastPathComponent().appendingPathComponent("empty", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            let archive = source.deletingLastPathComponent().appendingPathComponent("empty.zip")
            try zip(empty, to: archive)
            for candidate in [source.appendingPathComponent("missing"), empty, archive] {
                #expect(!(await model.importPackage(from: candidate)))
                #expect(settings.problem?.contains(L10n.tr("导入失败", "Import failed")) == true)
                #expect(settings.entries.isEmpty)
            }
            #expect(settings.problem?.contains("manifest.json") == true)
            #expect(try Data(contentsOf: configURL) == original)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(!FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().appendingPathComponent("plugins").path))
        }
    }

    @Test func unverifiedPluginCannotBeEnabledAndDoesNotChangeConfigurationOrRun() async throws {
        try await withFixture { model, settings, configURL, source, marker in
            #expect(await model.importPackage(from: source))
            let id = try #require(settings.selectedID)
            let original = try Data(contentsOf: configURL)
            #expect(!settings.selectedConnectionVerified)
            let enabled = await settings.setEnabledAndWait(true, id: id)
            #expect(!enabled)
            #expect(settings.problem?.contains(L10n.tr("先检测连接", "Check the connection")) == true)
            #expect(settings.selected?.enabled == false)
            #expect(!settings.busy)
            #expect(try Data(contentsOf: configURL) == original)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func switchingOnChecksFirstAndStaysOffWhenTheCheckFails() async throws {
        try await withFixture { model, settings, configURL, source, _ in
            #expect(await model.importPackage(from: source))
            let id = try #require(settings.selectedID)
            let original = try Data(contentsOf: configURL)
            #expect(!(await settings.checkAndEnable(id: id)))
            let entry = try #require(settings.selected)
            #expect(!entry.enabled)
            #expect(entry.tone == .warn)
            #expect(!entry.status.isEmpty)
            #expect(settings.checkingID == nil && !settings.busy)
            #expect(try Data(contentsOf: configURL) == original)
        }
    }

    @Test func plannedPlatformsAreListedButNeverEntries() async throws {
        try await withFixture { _, settings, configURL, _, _ in
            let original = try Data(contentsOf: configURL)
            #expect(PlatformSettings.planned.map(\.name) == [L10n.tr("飞书", "Lark"), "Slack", "Discord"])
            for platform in PlatformSettings.planned {
                settings.select(platform.id)
                #expect(settings.selectedID == nil)
                #expect(!settings.entries.contains { $0.id == platform.id || $0.name == platform.name })
            }
            #expect(try Data(contentsOf: configURL) == original)
        }
    }

    @Test func terminalScriptShowsTheCommandRunsItAndDeletesItself() {
        let command = #"PATH="$HOME/.local/bin:$PATH" examplechat login 'o'\''neil@example.com'"#
        let lines = TerminalRunner.script(for: command).components(separatedBy: "\n")
        #expect(lines[0] == "#!/bin/zsh -l")
        #expect(lines[1] == #"rm -f -- "$0""#)
        #expect(lines[2].hasPrefix("print -r -- '"))
        #expect(lines[3] == command)
        #expect(lines.contains { $0.contains(L10n.tr("检测并启用", "Check and enable")) })
    }

    /// The line that shows the command must print it as written: no
    /// substitution, no variable expansion, quotes intact.
    @Test func terminalScriptEchoDoesNotExpandTheCommand() throws {
        let command = #"PATH="$HOME/bin" examplechat login 'o'\''neil@example.com' $(whoami) `id`"#
        let script = TerminalRunner.script(for: command)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-script-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let echo = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix("print -r --") })
        let file = directory.appendingPathComponent("echo.zsh")
        try echo.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", file.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(printed == "$ " + command + "\n")
    }

    @Test func providerHelpLinkAcceptsOnlyHTTPS() {
        for value in ["http://example.com/help", "file:///tmp/help", "javascript:alert(1)", "/help", "https:"] {
            #expect(PluginSetup(summary: nil, requirements: nil, steps: nil, helpURL: value).safeHelpURL == nil)
        }
        let setup = PluginSetup(summary: nil, requirements: nil, steps: nil, helpURL: "https://example.com/help")
        #expect(setup.safeHelpURL?.absoluteString == "https://example.com/help")
    }

    private func zip(_ folder: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, archive.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func withFixture(_ body: (AddChatToolModel, PlatformSettings, URL, URL, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-tool-setup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let configURL = directory.appendingPathComponent("config.json")
        let marker = directory.appendingPathComponent("plugin-executed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "protocol_version": 1, "id": "test.company", "name": "Company Chat", "version": "1.0.0",
            "transport": "command-v1", "entrypoint": ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
            "capabilities": ["conversations.list": true, "messages.read": true, "composer.read": true, "composer.apply": true],
            "desktop": [
                "strategy": "ax-ocr-v1", "bundle_ids": ["test.company.desktop"],
                "header": ["top_offset": 28, "height": 64, "left_padding": 0],
                "overlay": ["font_size": 13, "offset_x": 0, "offset_y": 0], "send_shortcut": "return",
            ],
            "setup": ["summary": "先完成提供方的登录流程", "requirements": ["安装公司提供的客户端"],
                      "steps": ["登录公司账号", "返回 Tact 检测连接"], "help_url": "https://example.com/help"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
        try "import pathlib\npathlib.Path(\(String(reflecting: marker.path))).touch()\n"
            .write(to: source.appendingPathComponent("adapter.py"), atomically: true, encoding: .utf8)
        let file = ConfigFile(root: ["platforms": []])
        try file.write(to: configURL.path)
        var config = AppConfig()
        config.socketPath = directory.appendingPathComponent("no-engine.sock").path
        config.engineCommand = ["/usr/bin/false"]
        let settings = PlatformSettings(controller: Controller(config: config), file: file, configPath: configURL.path)
        let model = AddChatToolModel(settings: settings)
        try await body(model, settings, configURL, source, marker)
    }
}
