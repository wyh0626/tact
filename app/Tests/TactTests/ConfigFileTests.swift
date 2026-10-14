import Foundation
import Testing
@testable import Tact

struct ConfigFileTests {
    @Test func setAndReadNestedPaths() {
        var file = ConfigFile(root: ["model": ["model": "a", "keep": 1]])
        file.set("model.model", "b")
        file.set("model.extra_body.thinking", ["type": "disabled"])
        #expect(file.string("model.model") == "b")
        #expect(file.value("model.keep") as? Int == 1)
        #expect(file.value("model.extra_body.thinking.type") as? String == "disabled")
        file.set("model.extra_body.thinking", nil)
        #expect(file.value("model.extra_body.thinking") == nil)
    }

    @Test func writeKeepsUnknownKeysAndIsPrivate() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var file = ConfigFile(root: ["style": ["chat_sections": ["李四": "朋友聊天"]], "socket": "~/s.sock"])
        file.set("app.hotkey", "double+ctrl")
        try file.write(to: path)
        let back = try ConfigFile.load(from: path)
        #expect((back.value("style.chat_sections") as? [String: String])?["李四"] == "朋友聊天")
        #expect(back.string("app.hotkey") == "double+ctrl")
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func originAndAllowList() {
        #expect(ConfigFile.origin(of: "https://api.deepseek.com/v1") == "https://api.deepseek.com")
        #expect(ConfigFile.origin(of: "http://127.0.0.1:11434/v1") == "http://127.0.0.1:11434")
        #expect(ConfigFile.origin(of: "api.deepseek.com/v1") == nil)
        var file = ConfigFile(root: ["model": ["allowed_base_urls": ["http://127.0.0.1:11434"]]])
        file.allowModelOrigin(of: "https://gateway.example.com/v1")
        file.allowModelOrigin(of: "https://gateway.example.com/v2")
        #expect(file.strings("model.allowed_base_urls") == ["http://127.0.0.1:11434", "https://gateway.example.com"])
    }

    @Test func providerMatching() {
        #expect(ModelProvider.matching(provider: nil, baseURL: "https://api.deepseek.com/v1") == .deepseek)
        #expect(ModelProvider.matching(provider: nil, baseURL: "http://127.0.0.1:11434/v1") == .custom, "Ollama is a custom endpoint")
        #expect(ModelProvider.matching(provider: "local", baseURL: "") == .local)
        #expect(ModelProvider.matching(provider: nil, baseURL: "https://gateway.example.com/v1") == .custom)
        // Same endpoint as OpenAI with a key; told apart by model.provider.
        #expect(ModelProvider.matching(provider: nil, baseURL: "https://api.openai.com/v1") == .openai)
        #expect(ModelProvider.matching(provider: "chatgpt", baseURL: "https://api.openai.com/v1") == .chatgpt)
    }

    @Test func initialConfigWritesForEngine() throws {
        let path = ProcessInfo.processInfo.environment["TACT_INITIAL_CONFIG_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("initial-config.json").path
        try ConfigFile.initial(styleFile: "/tmp/style.md",
                               feedbackFile: "/tmp/feedback.jsonl").write(to: path)
        let back = try ConfigFile.load(from: path)
        #expect(back.string("model.base_url") == ModelProvider.deepseek.baseURL)
        #expect(back.strings("model.allowed_base_urls").contains("https://api.deepseek.com"))
        #expect(back.string("app.hotkey") == "double+ctrl")
    }
}

@MainActor
struct ModelSettingsTests {
    @Test func writesEndpointAllowListAndThinkingSwitch() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["base_url": "http://127.0.0.1:11434/v1", "model": "qwen2.5:7b",
                                               "allowed_base_urls": ["http://127.0.0.1:11434"]]])
        let settings = ModelSettings(file: file)
        #expect(settings.provider == .custom)
        settings.choose(.deepseek)
        #expect(settings.model == "deepseek-flash" && settings.reasoningEffort == "none")
        settings.write(into: &file)
        #expect(file.string("model.base_url") == "https://api.deepseek.com/v1")
        #expect(file.strings("model.allowed_base_urls").contains("https://api.deepseek.com"))
        #expect(file.value("model.extra_body.thinking.type") as? String == "disabled")
        #expect(file.string("model.api_key_env") == AppConfig.defaultAPIKeyEnv)

        settings.choose(.custom)
        settings.write(into: &file)
        #expect(file.value("model.extra_body") == nil)
    }

    @Test func chatgptWritesProviderAndNeedsSignIn() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["base_url": "https://api.deepseek.com/v1", "model": "deepseek-flash",
                                               "extra_body": ["thinking": ["type": "disabled"]]]])
        let settings = ModelSettings(file: file)
        settings.chatgptModels = [ChatGPTModel(slug: "gpt-fast", displayName: "GPT Fast")]
        settings.choose(.chatgpt)
        #expect(settings.model == "gpt-fast")
        #expect(settings.validationError == L10n.tr("先用 ChatGPT 账号登录", "Sign in with ChatGPT first"))
        settings.chatgpt = ChatGPTStatus(signedIn: true, email: "me@example.com", planUsage: false, loginPending: false, loginError: nil)
        #expect(settings.validationError?.contains(L10n.tr("没有授权", "was not authorized")) == true)
        settings.chatgpt = ChatGPTStatus(signedIn: true, email: "me@example.com", planUsage: true, loginPending: false, loginError: nil)
        #expect(settings.validationError == nil)

        settings.write(into: &file)
        #expect(file.string("model.provider") == "chatgpt")
        #expect(file.string("model.base_url") == "https://api.openai.com/v1")
        #expect(file.string("model.model") == "gpt-fast")
        #expect(file.strings("model.allowed_base_urls").contains("https://api.openai.com"))
        #expect(file.value("model.extra_body") == nil)

        settings.choose(.deepseek)
        #expect(settings.model == "deepseek-flash")
        settings.write(into: &file)
        #expect(file.value("model.provider") == nil)
    }

    @Test func deepseekEffortTurnsThinkingOnOrOff() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: [:])
        let settings = ModelSettings(file: file)
        settings.choose(.deepseek)
        #expect(settings.speedOptions.levels.map(\.effort) == ["none", "low", "high", "max"])
        #expect(settings.speedOptions.fastTier == nil)
        settings.write(into: &file)
        #expect(file.value("model.extra_body.thinking.type") as? String == "disabled")
        #expect(file.value("model.reasoning_effort") == nil)
        settings.reasoningEffort = "high"
        settings.write(into: &file)
        #expect(file.value("model.extra_body") == nil)
        #expect(file.string("model.reasoning_effort") == "high")
        // Reading it back keeps the choice.
        #expect(ModelSettings(file: file).reasoningEffort == "high")
    }

    @Test func chatgptSpeedFollowsModelMetadata() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: [:])
        let settings = ModelSettings(file: file)
        settings.chatgptModels = [
            ChatGPTModel(slug: "fast", displayName: "Fast",
                         reasoningLevels: [.init(effort: "low", description: ""), .init(effort: "high", description: "")],
                         defaultReasoning: "low",
                         speedTiers: [.init(id: "priority", name: "Fast", description: "2x speed, increased usage")]),
            ChatGPTModel(slug: "plain", displayName: "Plain", reasoningLevels: [.init(effort: "medium", description: "")]),
        ]
        settings.choose(.chatgpt)
        settings.model = "fast"
        settings.reconcileSpeed()
        let options = settings.speedOptions
        #expect(options.levels.map(\.effort) == ["low", "high"])
        #expect(options.levels.first?.detail.hasPrefix(L10n.tr("模型默认", "Model default")) == true)
        #expect(settings.reasoningEffort == "low", "the model's default level starts selected")
        #expect(options.fastTier == .init(id: "priority", detail: L10n.tr("约 2 倍速度，会更快消耗套餐额度", "About 2× faster, uses your plan allowance faster")))

        settings.reasoningEffort = "high"
        settings.fastMode = true
        settings.write(into: &file)
        #expect((file.value("model.reasoning_effort") as? String) == "high")
        #expect((file.value("model.service_tier") as? String) == "priority")

        // A model with a single level and no Fast tier offers no choice:
        // it runs at its own default.
        settings.model = "plain"
        settings.reconcileSpeed()
        #expect(settings.speedOptions.isEmpty)
        #expect(settings.reasoningEffort == "" && !settings.fastMode)
        settings.write(into: &file)
        #expect(file.value("model.reasoning_effort") == nil && file.value("model.service_tier") == nil)
    }

    @Test func chatgptOffersOnlyTheLevelsAReplyNeeds() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "chatgpt", "reasoning_effort": "xhigh"]]))
        let all = ["low", "medium", "high", "xhigh", "max", "ultra"].map { ChatGPTModel.Level(effort: $0, description: "") }
        settings.chatgptModels = [ChatGPTModel(slug: "sol", displayName: "Sol", reasoningLevels: all, defaultReasoning: "medium")]
        settings.model = "sol"
        #expect(settings.speedOptions.levels.map(\.label) == [L10n.tr("低", "Low"), L10n.tr("中", "Medium"), L10n.tr("高", "High")])
        settings.reconcileSpeed()
        #expect(settings.reasoningEffort == "medium", "a level no longer offered falls back to the model default")

        // Without a usable default, the light level is the starting point.
        settings.chatgptModels = [ChatGPTModel(slug: "sol", displayName: "Sol", reasoningLevels: all, defaultReasoning: "xhigh")]
        settings.reasoningEffort = "ultra"
        settings.reconcileSpeed()
        #expect(settings.reasoningEffort == "low")
    }

    @Test func openAICardHoldsBothWaysIn() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        #expect(ModelProvider.cards.map(\.id) == ["openai", "deepseek", "local", "custom"])
        #expect(ModelProvider.chatgpt.cardID == "openai" && ModelProvider.openai.cardID == "openai")
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["base_url": "https://api.deepseek.com/v1"]]))
        #expect(!settings.usesOpenAI)
        settings.chooseCard(.openai)
        #expect(settings.provider == .chatgpt, "the OpenAI card starts on ChatGPT sign-in")
        settings.choose(.openai)
        #expect(settings.usesOpenAI && settings.provider == .openai)
        settings.chooseCard(.openai)
        #expect(settings.provider == .openai, "picking the chosen card keeps its sign-in method")
        settings.chooseCard(.deepseek)
        #expect(settings.provider == .deepseek && !settings.usesOpenAI)
    }

    @Test func chatgptStartsOnLunaWhenTheAccountHasIt() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let settings = ModelSettings(file: ConfigFile(root: [:]))
        settings.chatgptModels = [ChatGPTModel(slug: "gpt-6.1-sol", displayName: "GPT-6.1-Sol"),
                                  ChatGPTModel(slug: "gpt-5.6-luna", displayName: "GPT-5.6-Luna")]
        settings.choose(.chatgpt)
        #expect(settings.model == "gpt-5.6-luna")
        // An account without it starts on its first model.
        let other = ModelSettings(file: ConfigFile(root: [:]))
        other.chatgptModels = [ChatGPTModel(slug: "gpt-6.1-sol", displayName: "GPT-6.1-Sol")]
        other.choose(.chatgpt)
        #expect(other.model == "gpt-6.1-sol")
    }

    @Test func localModelsHaveNoSpeedOptions() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["reasoning_effort": "high", "service_tier": "priority"]])
        let settings = ModelSettings(file: file)
        settings.choose(.local)
        #expect(settings.speedOptions.isEmpty)
        settings.write(into: &file)
        #expect(file.value("model.reasoning_effort") == nil && file.value("model.service_tier") == nil)
    }

    @Test func tierDescriptions() {
        #expect(SpeedOptions.tierDetail("1.5x speed") == L10n.tr("约 1.5 倍速度", "About 1.5× faster"))
        #expect(SpeedOptions.tierDetail("increased usage") == L10n.tr("更快出结果，会更快消耗套餐额度", "Faster results, uses your plan allowance faster"))
    }

    @Test func validation() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let settings = ModelSettings(file: ConfigFile(root: [:]))
        settings.choose(.custom)
        settings.baseURL = "gateway/v1"
        #expect(settings.validationError != nil)
        settings.baseURL = "https://gateway.example.com/v1"
        settings.model = "m"
        #expect(settings.validationError == nil, "a custom endpoint may need no key, like Ollama")
        settings.choose(.deepseek)
        #expect(settings.validationError == L10n.tr("填写 API Key", "Enter an API key"))
    }
}
