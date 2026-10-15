import Foundation
import Testing
@testable import Tact

@MainActor
struct ReasoningSettingsTests {
    @Test func ordinaryCustomSavePreservesEveryManualSpeedOption() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let model: [String: Any] = [
            "base_url": "https://gateway.example.com/v1", "model": "company/model",
            "reasoning_effort": "high", "service_tier": "flex",
            "extra_body": [
                "thinking": ["type": "enabled", "vendor_setting": true],
                "reasoning": ["effort": "low", "exclude": true],
                "chat_template_kwargs": ["enable_thinking": true, "custom_template": "v2"],
                "vendor_flag": 7,
            ],
        ]
        var file = ConfigFile(root: ["model": model])
        let settings = ModelSettings(file: file)
        settings.apiKey = "replacement-key"
        settings.reconcileSpeed()
        settings.write(into: &file)
        #expect(file.string("model.reasoning_effort") == "high")
        #expect(file.string("model.service_tier") == "flex")
        #expect(try json(file.value("model.extra_body")) == json(model["extra_body"]))
        #expect(file.value("model.reasoning") == nil, "reading raw controls must not migrate them on save")
    }

    @Test func nativeRawSettingsAreInferredAndPreservedUntilEdited() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let cases: [(ModelProvider, String, [String: Any], String, String, Int)] = [
            (.anthropic, "claude-opus-4-6", ["thinking": ["type": "adaptive"],
                "output_config": ["effort": "high", "format": ["type": "json_schema", "schema": ["type": "object"]]]],
                "anthropic_effort", "high", 1024),
            (.gemini, "gemini-2.5-pro", ["generationConfig": ["thinkingConfig": ["thinkingBudget": 2048, "includeThoughts": true],
                "responseMimeType": "application/json"]], "gemini_budget", "enabled", 2048),
        ]
        for (provider, model, extra, format, effort, budget) in cases {
            var file = ConfigFile(root: ["model": ["provider": provider.id, "base_url": provider.baseURL,
                                                   "model": model, "max_tokens": 400, "extra_body": extra]])
            let settings = ModelSettings(file: file)
            #expect(settings.reasoningFormat == format && settings.reasoningEffort == effort)
            if format == "gemini_budget" { #expect(settings.thinkingBudget == budget) }
            settings.reconcileSpeed()
            settings.apiKey = "new-test-key"
            settings.write(into: &file)
            #expect(try json(file.value("model.extra_body")) == json(extra))
            #expect(file.value("model.reasoning") == nil)
        }
    }

    @Test func legacyClaudeCombinedBudgetAndEffortKeepsThinkingEnabled() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let extra: [String: Any] = ["thinking": ["type": "enabled", "budget_tokens": 2048],
                                   "output_config": ["effort": "high", "format": ["type": "json_schema"]]]
        var file = ConfigFile(root: ["model": ["provider": "anthropic", "base_url": ModelProvider.anthropic.baseURL,
                                               "model": "claude-opus-4-5", "max_tokens": 300, "extra_body": extra]])
        let settings = ModelSettings(file: file)
        #expect(settings.reasoningFormat == "anthropic_budget" && settings.reasoningEffort == "enabled")
        settings.reconcileSpeed()
        settings.write(into: &file)
        #expect(try json(file.value("model.extra_body")) == json(extra))
        #expect(file.value("model.reasoning") == nil)
        settings.thinkingBudget = 4096
        settings.write(into: &file)
        #expect(file.string("model.reasoning.format") == "anthropic_budget")
        #expect(file.string("model.reasoning.thinking_type") == "enabled")
        #expect(file.number("model.reasoning.budget_tokens") == 4096)
        #expect(file.string("model.extra_body.output_config.effort") == "high")
        #expect(file.string("model.extra_body.output_config.format.type") == "json_schema")
    }

    @Test func nativeEffortWritesTypedConfigurationAndKeepsSchema() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["provider": "anthropic", "base_url": ModelProvider.anthropic.baseURL,
                                               "model": "claude-opus-4-6", "max_tokens": 500,
                                               "extra_body": ["output_config": ["effort": "high", "format": ["type": "json_schema"]],
                                                              "metadata": ["user_id": "test"]]]])
        let settings = ModelSettings(file: file)
        settings.reasoningEffort = "low"
        settings.write(into: &file)
        #expect(file.string("model.reasoning.format") == "anthropic_effort")
        #expect(file.string("model.reasoning.effort") == "low")
        #expect(file.string("model.reasoning.thinking_type") == "adaptive")
        #expect(file.string("model.extra_body.output_config.format.type") == "json_schema")
        #expect(file.string("model.extra_body.metadata.user_id") == "test")
        let restored = ModelSettings(file: file)
        #expect(restored.reasoningEffort == "low" && restored.reasoningFormat == "anthropic_effort")
        settings.reasoningEffort = ""
        settings.write(into: &file)
        #expect(file.string("model.reasoning.effort") == "")
        #expect(file.value("model.reasoning.thinking_type") == nil)
    }

    @Test func budgetSettingsValidateAndPersistExactTokenBudget() async {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["provider": "anthropic", "base_url": ModelProvider.anthropic.baseURL,
                                               "model": "claude-sonnet-4-5-20250929", "max_tokens": 300]])
        let settings = ModelSettings(file: file)
        settings.apiKey = "test-key"
        await settings.loadModels { _ in
            ["ok": true, "catalog": [["id": "claude-sonnet-4-5-20250929", "capabilities": ["reasoning_supported": true,
                "reasoning_format": "anthropic_budget", "thinking_types": ["enabled", "disabled"], "can_disable": true]]]]
        }
        settings.reasoningEffort = "enabled"
        settings.thinkingBudget = 512
        #expect(settings.reasoningValidationError != nil)
        settings.thinkingBudget = 2048
        #expect(settings.reasoningValidationError == nil)
        settings.write(into: &file)
        #expect(file.string("model.reasoning.format") == "anthropic_budget")
        #expect(file.string("model.reasoning.thinking_type") == "enabled")
        #expect(file.number("model.reasoning.budget_tokens") == 2048)
        #expect(file.number("model.max_tokens") == 300, "engine expands the request cap without rewriting the user's saved cap")
    }

    @Test func geminiBudgetAllowsDynamicAndRejectsUnsupportedOff() async {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["provider": "gemini", "base_url": ModelProvider.gemini.baseURL,
                                               "model": "gemini-2.5-pro"]])
        let settings = ModelSettings(file: file)
        settings.apiKey = "test-key"
        await settings.loadModels { _ in
            ["ok": true, "catalog": [["id": "gemini-2.5-pro", "capabilities": ["reasoning_supported": true,
                "reasoning_format": "gemini_budget", "can_disable": false]]]]
        }
        settings.reasoningEffort = "enabled"
        settings.thinkingBudget = -1
        #expect(settings.reasoningValidationError == nil)
        settings.write(into: &file)
        #expect(file.number("model.reasoning.budget_tokens") == -1)
        settings.reasoningEffort = "none"
        #expect(settings.reasoningValidationError != nil, "the model list says thinking cannot be turned off")
    }

    @Test func customClaudeBetweenToolsIsNotInferredAsDeepSeek() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["base_url": "https://gateway.example.com/v1", "model": "claude-sonnet-5-5",
                                               "extra_body": ["thinking": ["type": "between_tools"]]]])
        let settings = ModelSettings(file: file)
        #expect(settings.reasoningFormat == "anthropic_effort" && settings.reasoningEffort == "none")
        settings.write(into: &file)
        #expect(file.string("model.extra_body.thinking.type") == "between_tools")
        #expect(file.value("model.reasoning") == nil)
        settings.choose(.deepseek)
        settings.choose(.custom)
        #expect(settings.reasoningFormat.isEmpty, "choosing custom requires an explicit parameter format")
    }

    @Test func customEndpointAdvancedReasoningKeepsUnrelatedNestedOptions() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["base_url": "https://gateway.example.com/v1", "model": "any-model",
                                               "extra_body": ["reasoning": ["exclude": true], "vendor_option": true]]])
        let settings = ModelSettings(file: file)
        #expect(settings.reasoningFormat.isEmpty && settings.reasoningCapability == nil)
        settings.extraBodyJSON = #"{"reasoning":{"effort":"high","exclude":true},"vendor_option":true}"#
        settings.write(into: &file)
        #expect(file.value("model.reasoning") == nil)
        #expect(file.string("model.extra_body.reasoning.effort") == "high")
        #expect(file.bool("model.extra_body.reasoning.exclude") == true)
        #expect(file.bool("model.extra_body.vendor_option") == true)
    }

    @Test func advancedGeminiParameterFamilyEditKeepsResponseAndThoughtOptions() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        var file = ConfigFile(root: ["model": ["base_url": "https://gateway.example.com/v1", "model": "gateway-model",
                                               "extra_body": ["generationConfig": ["thinkingConfig": ["thinkingLevel": "HIGH", "includeThoughts": true],
                                                                                    "responseMimeType": "application/json"]]]])
        let settings = ModelSettings(file: file)
        #expect(settings.reasoningFormat == "gemini_level")
        settings.extraBodyJSON = #"{"generationConfig":{"thinkingConfig":{"thinkingBudget":2048,"includeThoughts":true},"responseMimeType":"application/json"}}"#
        settings.write(into: &file)
        #expect(file.value("model.reasoning") == nil)
        #expect(file.number("model.extra_body.generationConfig.thinkingConfig.thinkingBudget") == 2048)
        #expect(file.value("model.extra_body.generationConfig.thinkingConfig.thinkingLevel") == nil)
        #expect(file.bool("model.extra_body.generationConfig.thinkingConfig.includeThoughts") == true)
        #expect(file.string("model.extra_body.generationConfig.responseMimeType") == "application/json")
    }

    @Test func changingNativeProtocolDropsIncompatibleSchemaButKeepsGatewayOptions() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        for (from, to, extra, removed) in [
            (ModelProvider.anthropic, ModelProvider.gemini,
             ["output_config": ["format": ["type": "json_schema"]], "thinking": ["type": "adaptive"], "vendor_option": true] as [String: Any],
             "output_config"),
            (.gemini, .anthropic,
             ["generationConfig": ["responseMimeType": "application/json"], "safetySettings": [["category": "test"]], "vendor_option": true],
             "generationConfig"),
        ] {
            var file = ConfigFile(root: ["model": ["provider": from.id, "base_url": from.baseURL,
                                                   "model": "old-model", "extra_body": extra]])
            let settings = ModelSettings(file: file)
            settings.choose(to)
            settings.write(into: &file)
            #expect(file.value("model.extra_body." + removed) == nil)
            #expect(file.bool("model.extra_body.vendor_option") == true)
        }
    }

    @Test func speedOnlySaveAndAdoptionCarryNativeBudget() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reasoning-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json").path
        let file = ConfigFile(root: ["model": ["provider": "gemini", "base_url": ModelProvider.gemini.baseURL,
                                               "model": "gemini-2.5-flash", "max_tokens": 300,
                                               "extra_body": ["generationConfig": ["thinkingConfig": ["thinkingBudget": 1024]]]],
                                     "app": ["hotkey": "double+ctrl"]])
        try file.write(to: path)
        let panel = ModelSettings(file: file)
        panel.reasoningEffort = "enabled"
        panel.thinkingBudget = 2048
        try panel.writeSpeedOnly(to: path)
        let back = try ConfigFile.load(from: path)
        #expect(back.number("model.reasoning.budget_tokens") == 2048)
        #expect(back.number("model.max_tokens") == 300 && back.string("app.hotkey") == "double+ctrl")
        let window = ModelSettings(file: file)
        window.adoptSpeed(from: panel)
        #expect(window.reasoningFormat == "gemini_budget" && window.reasoningEffort == "enabled" && window.thinkingBudget == 2048)
    }

    private func json(_ object: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: object ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
    }
}
