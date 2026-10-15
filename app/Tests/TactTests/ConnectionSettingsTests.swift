import Foundation
import Testing
@testable import Tact

@MainActor
struct ConnectionSettingsTests {
    @Test func customProtocolIsExplicitAndLegacyProtocolIsPreserved() {
        var legacy = ConfigFile(root: ["model": ["base_url": "https://gateway.example/v1", "model": "legacy"]])
        let settings = ModelSettings(file: legacy)
        settings.write(into: &legacy)
        #expect(legacy.string("model.provider") == nil && legacy.string("model.protocol") == nil)
        settings.choose(.custom)
        settings.apiProtocol = .anthropic
        settings.model = "claude-sonnet-4-6"
        settings.reconcileSpeed()
        settings.write(into: &legacy)
        #expect(legacy.string("model.provider") == "custom")
        #expect(legacy.string("model.protocol") == "anthropic")
        let restored = ModelSettings(file: legacy)
        #expect(restored.provider == .custom && restored.apiProtocol == .anthropic)
        #expect(restored.reasoningCapability?.format == "anthropic_effort")
    }

    @Test func commonProvidersHaveEditableEndpointsAndNoStaleDefaultModel() {
        for provider in [ModelProvider.zhipu, .moonshot, .qwen, .doubao, .siliconflow, .openrouter, .minimax] {
            var file = ConfigFile(root: [:])
            let settings = ModelSettings(file: file)
            settings.choose(provider)
            #expect(settings.model.isEmpty && settings.apiProtocol == .openai)
            settings.model = "user-entered-id"
            settings.baseURL = "https://regional.example/v1"
            settings.write(into: &file)
            #expect(file.string("model.provider") == provider.id && file.string("model.protocol") == "openai")
            #expect(ModelSettings(file: file).provider == provider)
            #expect(file.string("model.model") == "user-entered-id")
        }
        #expect(ModelProvider.minimax.baseURL == "https://api.minimax.cn/v1")
    }

    @Test func modelCatalogAcceptsManualIDsAndAPIReportedFalseOverridesBuiltin() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "anthropic", "base_url": ModelProvider.anthropic.baseURL,
                                                                     "model": "claude-sonnet-4-6"]]))
        settings.apiKey = "test-key"
        #expect(settings.reasoningCapability != nil)
        await settings.loadModels { request in
            #expect(request["op"] as? String == "model_catalog")
            let connection = request["connection"] as? [String: Any]
            #expect(connection?["protocol"] as? String == "anthropic")
            #expect(connection?["api_key"] as? String == "test-key")
            return ["ok": true, "catalog": [["id": "claude-sonnet-4-6", "name": "Sonnet",
                                             "capabilities": ["reasoning_supported": false]]]]
        }
        #expect(settings.availableModels.map(\.id) == ["claude-sonnet-4-6"])
        #expect(settings.reasoningCapability == nil && settings.speedOptions.isEmpty)
        #expect(settings.reasoningCapabilitySource == L10n.tr("接口返回", "Reported by API"))
        settings.model = "a-manually-entered-new-model"
        #expect(settings.reasoningCapability?.format == "anthropic_effort", "a model the list does not describe gets the protocol's controls")
        #expect(settings.validationError == nil, "unknown IDs are allowed")
    }

    @Test func partialAPICapabilityOverridesReportedFieldsAndRetainsMissingKnowledge() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "gemini", "base_url": ModelProvider.gemini.baseURL,
                                                                     "model": "gemini-2.5-flash"]]))
        settings.apiKey = "test-key"
        await settings.loadModels { _ in
            ["ok": true, "catalog": [["id": "gemini-2.5-flash", "capabilities": ["reasoning_supported": true, "reasoning_format": "gemini_budget",
                                                                                 "can_disable": false, "budget_max": 8192]]]]
        }
        #expect(settings.reasoningCapability?.budgetRange == 1...8192)
        #expect(settings.reasoningCapability?.efforts.contains("none") == false)
        #expect(settings.reasoningCapability?.format == "gemini_budget")
    }

    @Test func namesOnlyCatalogDoesNotInventCapabilitiesForUnknownCustomModel() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "custom", "protocol": "openai",
                                                                     "base_url": "https://example.test/v1", "model": "gateway-alias"]]))
        await settings.loadModels { _ in ["ok": true, "catalog": [["id": "gateway-alias"]]] }
        #expect(settings.availableModels.count == 1)
        #expect(settings.reasoningCapability == nil)
        #expect(settings.reasoningCapabilitySource == L10n.tr("能力未知", "Capabilities unknown"))
    }

    @Test func staleCatalogCannotApplyAfterConnectionChanges() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "custom", "base_url": "https://old.test/v1", "model": "alias"]]))
        await settings.loadModels { _ in
            settings.baseURL = "https://new.test/v1"
            return ["ok": true, "catalog": [["id": "old-model", "capabilities": ["reasoning_supported": true, "reasoning_format": "openai", "effort_levels": ["high"]]]]]
        }
        #expect(settings.availableModels.isEmpty && !settings.isLoadingModels)
        #expect(settings.modelLoadError == nil && settings.modelLoadMessage == nil)
    }

    @Test func newerCatalogWinsOverOutOfOrderResponse() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "custom", "base_url": "https://example.test/v1", "model": "alias"]]))
        await settings.loadModels { _ in
            await settings.loadModels { _ in ["ok": true, "catalog": [["id": "new-result"]]] }
            return ["ok": true, "catalog": [["id": "old-result"]]]
        }
        #expect(settings.availableModels.map(\.id) == ["new-result"])
        #expect(!settings.isLoadingModels)
    }

    @Test func keyAndHeaderChangesInvalidateCatalogAndRequestContainsOnlyTypedKey() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["base_url": "https://api.deepseek.com/v1", "model": "deepseek-flash"]]))
        settings.apiKey = "test-key"
        await settings.loadModels { request in
            #expect((request["connection"] as? [String: Any])?["provider"] as? String == "", "legacy saved provider is preserved for credential identity")
            return ["ok": true, "catalog": [["id": "deepseek-flash"]]]
        }
        #expect(settings.availableModels.count == 1)
        settings.headersJSON = #"{"X-Route":"test"}"#
        #expect(settings.availableModels.isEmpty)
        await settings.loadModels { request in
            #expect(((request["connection"] as? [String: Any])?["headers"] as? [String: String])?["X-Route"] == "test")
            return ["ok": true, "catalog": [["id": "deepseek-flash"]]]
        }
        settings.apiKey = "different-key"
        #expect(settings.availableModels.isEmpty)
    }

    @Test func advancedObjectsValidateAndPreserveUneditedConfiguration() throws {
        var file = ConfigFile(root: ["model": ["provider": "custom", "base_url": "https://example.test/v1", "model": "alias",
                                                "extra_body": ["vendor": ["enabled": true], "thinking": ["type": "enabled"]],
                                                "headers": ["X-Route": "original"]]])
        let original = try JSONSerialization.data(withJSONObject: file.root, options: [.sortedKeys])
        let settings = ModelSettings(file: file)
        settings.write(into: &file)
        #expect(try JSONSerialization.data(withJSONObject: file.value("model.extra_body")!, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: ["vendor": ["enabled": true], "thinking": ["type": "enabled"]], options: [.sortedKeys]))
        #expect(!original.isEmpty)
        settings.extraBodyJSON = "[]"
        #expect(settings.advancedValidationError != nil)
        settings.extraBodyJSON = #"{"vendor":{"enabled":false},"custom_limit":17}"#
        settings.headersJSON = #"{"X-Route":"edited"}"#
        #expect(settings.advancedValidationError == nil)
        settings.write(into: &file)
        #expect(file.bool("model.extra_body.vendor.enabled") == false)
        #expect(file.number("model.extra_body.custom_limit") == 17)
        #expect(file.string("model.headers.X-Route") == "edited")
        for invalid in [#"{"Authorization":"Bearer secret"}"#, #"{"Content-Type":"text/plain"}"#, #"{"X-Flag":true}"#, #"{"X-Flag":"first\nsecond"}"#,
                        #"{"X Route":"team-a"}"#, #"{"X:Route":"team-a"}"#, #"{"X-Route":"bad\u0000value"}"#] {
            settings.headersJSON = invalid
            #expect(settings.advancedValidationError != nil)
        }
    }

    @Test func advancedReasoningEditOverridesOldTypedControlAndVendorOnlyEditKeepsIt() {
        let original = ConfigFile(root: ["model": ["provider": "anthropic", "base_url": ModelProvider.anthropic.baseURL,
            "model": "claude-opus-4-6", "reasoning": ["format": "anthropic_effort", "effort": "high", "thinking_type": "adaptive"],
            "extra_body": ["metadata": ["user_id": "before"]]]])
        var file = original
        let settings = ModelSettings(file: original)
        settings.extraBodyJSON = #"{"metadata":{"user_id":"after"}}"#
        settings.write(into: &file)
        #expect(file.string("model.reasoning.effort") == "high", "unrelated raw edits keep the typed control")
        settings.extraBodyJSON = #"{"metadata":{"user_id":"after"},"thinking":{"type":"disabled"}}"#
        settings.write(into: &file)
        #expect(file.value("model.reasoning") == nil)
        #expect(file.string("model.extra_body.thinking.type") == "disabled")
        #expect(settings.usesAdvancedReasoningParameters)
        settings.reasoningEffort = "low"
        settings.write(into: &file)
        #expect(file.string("model.reasoning.effort") == "low", "a later UI edit explicitly takes control back")
        #expect(!settings.usesAdvancedReasoningParameters)
    }
    @Test func connectionChangesBindNewKeyAccountAndPreserveLegacyGlobalScope() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["base_url": "https://old.example/v1", "model": "alias"]])
        let settings = ModelSettings(file: file)
        #expect(settings.currentKeyAccount == Keychain.modelKey)
        settings.write(into: &file)
        #expect(file.string("model.api_key_account") == nil)
        settings.baseURL = "https://new.example/v1"
        #expect(settings.currentKeyAccount != Keychain.modelKey)
        let scoped = settings.currentKeyAccount
        settings.write(into: &file)
        #expect(file.string("model.api_key_account") == scoped)
        #expect(ModelSettings(file: file).currentKeyAccount == scoped)
        settings.baseURL = "https://old.example/another-route"
        #expect(settings.currentKeyAccount == Keychain.modelKey, "the original credential stays available to its original connection")
        settings.write(into: &file)
        #expect(file.string("model.api_key_account") == nil, "saving the original connection restores its original credential account")
        settings.apiProtocol = .responses
        #expect(settings.currentKeyAccount != Keychain.modelKey)
    }

    /// A setup from before per-connection keys: after saving another
    /// connection, going back to the original one still finds its key.
    @Test func aSavedKeyLoadsTheModelListWithoutAClick() async {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let account = "model-api-key-auto-catalog-\(UUID().uuidString.prefix(8).lowercased())"
        Keychain.save("saved-test-key", account: account)
        defer { Keychain.save("", account: account) }
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "moonshot", "base_url": ModelProvider.moonshot.baseURL,
                                                                     "model": "kimi-k2.6", "api_key_account": account]]))
        #expect(settings.automaticCatalogIdentity != nil)
        await settings.loadModels { _ in ["ok": true, "catalog": [["id": "kimi-k2.6"]]] }
        #expect(settings.automaticCatalogIdentity == nil, "a loaded list is not fetched again")
        settings.apiKey = "typed-test-key"
        #expect(settings.automaticCatalogIdentity == nil, "a key being typed is sent only when asked")
        let unsaved = ModelSettings(file: ConfigFile(root: ["model": ["provider": "moonshot", "base_url": ModelProvider.moonshot.baseURL,
                                                                    "api_key_account": account + "-missing"]]))
        #expect(unsaved.automaticCatalogIdentity == nil)
    }

    @Test func leavingTheOriginalConnectionKeepsItsKeyForTheWayBack() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let original = "https://legacy-\(UUID().uuidString.prefix(8).lowercased()).example/v1"
        Keychain.save("legacy-key", account: Keychain.modelKey)
        var file = ConfigFile(root: ["model": ["base_url": original, "model": "alias"]])
        let settings = ModelSettings(file: file)
        settings.baseURL = "https://new-\(UUID().uuidString.prefix(8).lowercased()).example/v1"
        settings.write(into: &file)
        let later = ModelSettings(file: file)
        later.baseURL = original
        #expect(later.currentKeyAccount != Keychain.modelKey)
        #expect(Keychain.read(later.currentKeyAccount) == "legacy-key")
        Keychain.save("", account: later.currentKeyAccount)
        Keychain.save("", account: Keychain.modelKey)
    }

    @Test func advancedCapsKeepLegacyValuesAndNewConnectionUsesReasonableHeadroom() {
        var file = ConfigFile(root: ["model": ["provider": "deepseek", "base_url": ModelProvider.deepseek.baseURL,
                                                "model": "deepseek-flash", "max_tokens": 300, "timeout_ms": 20000]])
        let settings = ModelSettings(file: file)
        settings.write(into: &file)
        #expect(file.number("model.max_tokens") == 300 && file.number("model.timeout_ms") == 20000)
        settings.choose(.moonshot)
        #expect(settings.maxTokens == 4096 && settings.timeoutMS == 60000)
        settings.write(into: &file)
        #expect(file.number("model.max_tokens") == 4096 && file.number("model.timeout_ms") == 60000)
        settings.maxTokens = 0
        #expect(settings.advancedValidationError != nil)
        settings.maxTokens = 8192
        settings.timeoutMS = 999
        #expect(settings.advancedValidationError != nil)
        settings.timeoutMS = 120000
        #expect(settings.advancedValidationError == nil)
        settings.write(into: &file)
        #expect(file.number("model.max_tokens") == 8192 && file.number("model.timeout_ms") == 120000)
    }

    @Test func openAIStartsAtLowReasoning() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["provider": "deepseek", "base_url": ModelProvider.deepseek.baseURL, "model": "deepseek-flash"]])
        let settings = ModelSettings(file: file)
        settings.choose(.openai)
        settings.reconcileSpeed()
        settings.model = "gpt-5.5"
        settings.reconcileSpeed()
        #expect(settings.reasoningEffort == "low")
        settings.apiKey = "test-key"
        settings.write(into: &file)
        #expect(file.string("model.reasoning_effort") == "low")
    }

    @Test func presetsWithOneParameterFamilyOfferItForEveryModel() {
        for (provider, model, format, efforts) in [
            (ModelProvider.deepseek, "deepseek-next", "deepseek", ["", "none", "low", "high", "max"]),
            (.openai, "gpt-9-unreleased", "openai", ["", "low", "medium", "high"]),
            (.qwen, "qwen-next", "qwen", ["", "none", "enabled"]),
        ] {
            let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": provider.id, "base_url": provider.baseURL, "model": model]]))
            #expect(settings.reasoningCapability?.format == format)
            #expect(settings.speedOptions.levels.map(\.effort) == efforts)
        }
        var file = ConfigFile(root: ["model": ["provider": "qwen", "base_url": ModelProvider.qwen.baseURL, "model": "qwen-next"]])
        let qwen = ModelSettings(file: file)
        qwen.reasoningEffort = "enabled"
        qwen.write(into: &file)
        #expect(file.string("model.reasoning.format") == "qwen" && file.string("model.reasoning.effort") == "enabled")
        for provider in ["zhipu", "moonshot", "minimax", "siliconflow", "openrouter", "doubao", "custom"] {
            #expect(ReasoningCapabilities.knownProfile(provider: provider, protocol: .openai) == nil,
                    "\(provider) models differ in parameter family, so controls come from the API")
        }
        #expect(ReasoningCapabilities.knownProfile(provider: "qwen", protocol: .responses) == nil)
        #expect(ReasoningCapabilities.knownProfile(provider: "openai", protocol: .responses)?.format == "openai")
    }

    @Test func deepseekDefaultLeavesThinkingToServiceInsteadOfDisablingIt() {
        var file = ConfigFile(root: ["model": ["provider": "deepseek", "base_url": ModelProvider.deepseek.baseURL,
                                                "model": "deepseek-flash", "extra_body": ["thinking": ["type": "disabled"]]]])
        let settings = ModelSettings(file: file)
        settings.reasoningEffort = ""
        settings.write(into: &file)
        #expect(file.string("model.extra_body.thinking.type") == nil)
        #expect(file.string("model.reasoning_effort") == nil)
    }

    @Test func budgetOnlyAPIMetadataStillOffersThinkingToggleWithoutEffortLevels() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "anthropic", "base_url": ModelProvider.anthropic.baseURL,
                                                                     "model": "claude-sonnet-4-5"]]))
        settings.apiKey = "test-key"
        await settings.loadModels { _ in
            ["ok": true, "catalog": [["id": "claude-sonnet-4-5", "capabilities": ["reasoning_supported": true,
                "reasoning_format": "anthropic_budget", "effort_levels": [], "thinking_types": ["enabled", "disabled"], "can_disable": true]]]]
        }
        #expect(settings.reasoningCapability?.efforts == ["", "none", "enabled"])
        #expect(settings.usesThinkingBudget)
    }

    @Test func changingCustomProtocolDoesNotRetainIncompatibleLegacyFamily() {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["base_url": "https://example.test/v1", "model": "claude-sonnet-4-6",
            "extra_body": ["thinking": ["type": "disabled"], "reasoning_effort": "high"]]]))
        settings.apiProtocol = .anthropic
        settings.reconcileSpeed()
        #expect(settings.reasoningCapability?.format == "anthropic_effort")
        #expect(settings.reasoningFormat == "anthropic_effort")
    }

    @Test func selectedAPICapabilitiesPersistWithoutSecretsAndRemainConnectionBound() async throws {
        var file = ConfigFile(root: ["model": ["provider": "custom", "protocol": "openai", "base_url": "https://gateway.test/v1", "model": "alias"]])
        let settings = ModelSettings(file: file)
        settings.apiKey = "ephemeral-test-secret"
        settings.headersJSON = #"{"X-Route":"one"}"#
        await settings.loadModels { _ in
            ["ok": true, "catalog": [["id": "alias", "capabilities": ["reasoning_supported": true,
                "reasoning_format": "reasoning", "effort_levels": ["none", "low", "high"]]]]]
        }
        #expect(settings.speedOptions.levels.map(\.effort) == ["", "none", "low", "high"])
        settings.reasoningEffort = "high"
        settings.write(into: &file)
        let cache = try #require(file.value("model.capability_cache") as? [String: Any])
        let serialized = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
        #expect(String(decoding: serialized, as: UTF8.self).contains("ephemeral-test-secret") == false)
        let restored = ModelSettings(file: file)
        #expect(restored.speedOptions.levels.map(\.effort) == ["", "none", "low", "high"])
        #expect(restored.reasoningCapabilitySource == L10n.tr("上次接口返回", "Last API response"))
        restored.headersJSON = #"{"X-Route":"two"}"#
        #expect(restored.reasoningCapabilitySource != L10n.tr("上次接口返回", "Last API response"))
        let changedRoute = ModelSettings(file: file)
        changedRoute.baseURL = "https://gateway.test/other-route"
        #expect(changedRoute.reasoningCapabilitySource != L10n.tr("上次接口返回", "Last API response"))
        let changedModel = ModelSettings(file: file)
        changedModel.model = "another-model"
        #expect(changedModel.reasoningCapability == nil)
        let refreshed = ModelSettings(file: file)
        await refreshed.loadModels { _ in ["ok": true, "catalog": [["id": "alias", "capabilities": ["reasoning_supported": false]]]] }
        #expect(refreshed.reasoningCapability == nil, "new API information overrides the cached capabilities")
    }

    @Test func APIReportedNoneIsOfferedUnlessExplicitlyDisallowed() {
        let reported = RemoteModelCapabilities(reasoningSupported: true, reasoningFormat: "openai", effortLevels: ["none", "low", "ultra"])
        #expect(ReasoningCapabilities.resolving(reported, fallback: nil, protocol: .openai)?.efforts == ["", "none", "low"])
        var restricted = reported
        restricted.canDisable = false
        #expect(ReasoningCapabilities.resolving(restricted, fallback: nil, protocol: .openai)?.efforts == ["", "low"])
    }

    @Test func customNativeProtocolsRequireKeyAndSwitchingProviderClearsTemporaryCredentials() {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "custom", "base_url": "https://gateway.test/v1", "model": "alias"]]))
        #expect(!settings.keyRequired)
        settings.apiProtocol = .anthropic
        #expect(settings.keyRequired)
        settings.apiProtocol = .gemini
        #expect(settings.keyRequired)
        settings.apiKey = "temporary-provider-key"
        settings.headersJSON = #"{"X-Custom-Auth":"temporary-header-secret"}"#
        settings.choose(.zhipu)
        #expect(settings.apiKey.isEmpty && settings.headersJSON == "{}")
    }

    @Test func changingOriginClearsTemporaryCredentialsButChangingPathKeepsThem() {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "custom", "base_url": "https://gateway.test/v1", "model": "alias"]]))
        settings.apiKey = "temporary-provider-key"
        settings.headersJSON = #"{"X-Route":"private"}"#
        settings.baseURL = "https://gateway.test:443/other-route"
        #expect(settings.apiKey == "temporary-provider-key" && settings.headersJSON.contains("private"))
        settings.baseURL = "https://another.test/v1"
        #expect(settings.apiKey.isEmpty && settings.headersJSON == "{}")
    }

    @Test func unknownBudgetOnlyAPIModelOffersBudgetInTheProtocolRange() async {
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "custom", "protocol": "anthropic", "base_url": "https://gateway.test", "model": "new-native-model"]]))
        settings.apiKey = "test-key"
        await settings.loadModels { _ in
            ["ok": true, "catalog": [["id": "new-native-model", "capabilities": ["reasoning_supported": true,
                "reasoning_format": "anthropic_budget", "effort_levels": [], "thinking_types": ["enabled", "disabled"], "can_disable": true]]]]
        }
        #expect(settings.reasoningCapability?.efforts == ["", "none", "enabled"])
        #expect(settings.usesThinkingBudget && settings.reasoningCapability?.budgetRange == 1024...32768,
                "bounds the API leaves out use the protocol's range")
        settings.reasoningEffort = "enabled"
        settings.thinkingBudget = 2048
        var file = ConfigFile(root: [:])
        settings.write(into: &file)
        #expect(file.number("model.reasoning.budget_tokens") == 2048)
    }

}
