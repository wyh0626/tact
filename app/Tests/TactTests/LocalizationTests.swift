import AppKit
import SwiftUI
import Testing
@testable import Tact

struct LanguageResolutionTests {
    @Test func systemMatchesSupportedLanguagesAndFallsBackToEnglish() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en-US"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en_GB", "zh-Hans"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "zh-TW"]) == .simplifiedChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["de-DE"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == .english)
        #expect(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]) == .simplifiedChinese)
    }

    @MainActor @Test func preferenceSurvivesReloadAndInvalidValuesUseSystem() throws {
        let name = "tact-language-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppLanguage.saved(in: defaults) == .system)
        let settings = LanguageSettings(defaults: defaults)
        settings.selection = .english
        #expect(LanguageSettings(defaults: defaults).selection == .english)
        #expect(settings.locale.language.languageCode?.identifier == "en")
        settings.selection = .simplifiedChinese
        #expect(LanguageSettings(defaults: defaults).resolvedLanguage == .simplifiedChinese)
        defaults.set("unsupported-language", forKey: AppLanguage.preferenceKey)
        #expect(AppLanguage.saved(in: defaults) == .system)
    }

    @MainActor @Test(arguments: [AppLanguage.english, .simplifiedChinese])
    func localizedLabelsAndNativeMenusKeepStableActions(language: AppLanguage) throws {
        try L10n.$overrideLanguage.withValue(language) {
            let english = language == .english
            #expect(SettingsPane.general.title == (english ? "General" : "通用"))
            #expect(ModelProvider.local.name == (english ? "Local" : "本机"))
            #expect(WeChatAssistant().name == (english ? "WeChat" : "微信"))
            #expect(EngineError.timeout.errorDescription == (english ? "The engine timed out" : "引擎响应超时"))
            let menu = AppDelegate.makeMainMenu()
            let edit = try #require(menu.items.first { $0.title == (english ? "Edit" : "编辑") }?.submenu)
            let paste = try #require(edit.items.first { $0.action == #selector(NSText.paste(_:)) })
            #expect(paste.title == (english ? "Paste" : "粘贴") && paste.keyEquivalent == "v")
            #expect(ModelProvider.local.id == "local")
            #expect(PracticeChat.opening.count == 5)
            #expect(PracticeChat.friend == (english ? "Lin" : "小林"))
        }
    }

    @Test func englishBootstrapSelectsMatchingStyleAndKeepsExistingUserFiles() throws {
        try L10n.$overrideLanguage.withValue(.english) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("english-bootstrap-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("resources")
            let state = root.appendingPathComponent("state")
            let config = state.appendingPathComponent("config.json").path
            let style = state.appendingPathComponent("style.md")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try "## 工作聊天\n中文示例".write(to: resources.appendingPathComponent("style.example.md"), atomically: true, encoding: .utf8)
            let english = "## Work chats\nMatch the language of the conversation"
            try english.write(to: resources.appendingPathComponent("style.example.en.md"), atomically: true, encoding: .utf8)
            AppConfig.bootstrapIfNeeded(configPath: config, resources: resources, stateDirectory: state.path, log: { _ in })
            #expect(try String(contentsOf: style, encoding: .utf8) == english)
            #expect(try ConfigFile.load(from: config).string("style.default_section") == "Work chats")
            try "My own style".write(to: style, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: URL(fileURLWithPath: config))
            AppConfig.bootstrapIfNeeded(configPath: config, resources: resources, stateDirectory: state.path, log: { _ in })
            #expect(try String(contentsOf: style, encoding: .utf8) == "My own style")
            #expect(try Data(contentsOf: URL(fileURLWithPath: config)) == before)
        }
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese])
    func configurationResetKeepsTheExistingStyleSection(language: AppLanguage) throws {
        try L10n.$overrideLanguage.withValue(language) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("retained-style-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("resources")
            let state = root.appendingPathComponent("state")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            try "## 工作聊天\n示例".write(to: resources.appendingPathComponent("style.example.md"), atomically: true, encoding: .utf8)
            try "## Work chats\nExample".write(to: resources.appendingPathComponent("style.example.en.md"), atomically: true, encoding: .utf8)
            let retainedSection = language == .english ? "工作聊天" : "Work chats"
            let retainedStyle = "## \(retainedSection)\nMy own preferences"
            let style = state.appendingPathComponent("style.md")
            try retainedStyle.write(to: style, atomically: true, encoding: .utf8)
            let config = state.appendingPathComponent("config.json").path
            AppConfig.bootstrapIfNeeded(configPath: config, resources: resources, stateDirectory: state.path, log: { _ in })
            #expect(try ConfigFile.load(from: config).string("style.default_section") == retainedSection)
            #expect(try String(contentsOf: style, encoding: .utf8) == retainedStyle)
        }
    }
}

