import Foundation
import Testing
@testable import Tact

struct ModelKeyScopeTests {
    @Test func scopeIsStableAcrossEquivalentOrigins() {
        let account = ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "https://gateway.example/v1")
        #expect(account == ModelKeyScope.account(provider: " CUSTOM ", protocol: " OpenAI ",
                                                baseURL: " HTTPS://GATEWAY.EXAMPLE:443/v2?route=test#fragment "))
        #expect(account.hasPrefix(Keychain.modelKey + "-"))
        #expect(account.count == Keychain.modelKey.count + 1 + 64)
        #expect(!account.contains("gateway.example"))
        #expect(ModelKeyScope.origin(of: "http://localhost:80/v1") == "http://localhost")
        #expect(ModelKeyScope.origin(of: "http://localhost:11434/v1") == "http://localhost:11434")
    }

    @Test func differentConnectionsDoNotShareAccounts() {
        let baseline = ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "https://first.example/v1")
        let alternatives = [
            ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "https://second.example/v1"),
            ModelKeyScope.account(provider: "openai", protocol: "openai", baseURL: "https://first.example/v1"),
            ModelKeyScope.account(provider: "custom", protocol: "anthropic", baseURL: "https://first.example/v1"),
            ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "http://first.example/v1"),
            ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "https://first.example:8443/v1"),
        ]
        #expect(alternatives.allSatisfy { $0 != baseline })
        #expect(Set(alternatives).count == alternatives.count)
    }

    @Test func invalidURLStillProducesDeterministicDistinctAccounts() {
        #expect(ModelKeyScope.origin(of: "not a URL") == nil)
        let first = ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "not a URL")
        #expect(first == ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: " not a URL\n"))
        #expect(first != ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "another invalid URL"))
    }

    @Test func appConfigReadsScopedAccountAndKeepsLegacyFallback() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tact-key-scope-\(UUID().uuidString).json").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        for account in [nil, "", "   ", "model-api-key-test-connection"] as [String?] {
            var file = ConfigFile(root: ["model": ["api_key_env": "MY_MODEL_KEY"]])
            file.set("model.api_key_account", account)
            try file.write(to: path)
            let (config, problem) = AppConfig.load(from: path)
            #expect(problem == nil)
            #expect(config.apiKeyEnv == "MY_MODEL_KEY")
            let expected = account.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? Keychain.modelKey
            #expect(config.modelKeyAccount == expected)
        }
    }

    @Test func engineEnvironmentNeverReusesInheritedKeyForANewConnection() {
        var config = AppConfig()
        let inherited = ["PATH": "/test/bin", AppConfig.defaultAPIKeyEnv: "previous-connection-key"]
        #expect(config.engineEnvironment(inheriting: inherited, modelKey: nil) == inherited,
                "legacy env-only setups keep their key")
        config.modelKeyAccount = ModelKeyScope.account(provider: "custom", protocol: "openai", baseURL: "https://new.example/v1")
        let anonymous = config.engineEnvironment(inheriting: inherited, modelKey: nil)
        #expect(anonymous[AppConfig.defaultAPIKeyEnv] == nil)
        #expect(anonymous["PATH"] == "/test/bin")
        let scoped = config.engineEnvironment(inheriting: inherited, modelKey: "new-connection-key")
        #expect(scoped[AppConfig.defaultAPIKeyEnv] == "new-connection-key")
        #expect(config.engineEnvironment(inheriting: inherited, modelKey: "")[AppConfig.defaultAPIKeyEnv] == nil)
    }

    @Test func customKeyEnvironmentUsesOnlyTheSelectedAccount() {
        var config = AppConfig()
        config.apiKeyEnv = "CUSTOM_MODEL_KEY"
        config.modelKeyAccount = "scoped-model-account"
        let inherited = ["CUSTOM_MODEL_KEY": "old-custom-key", "UNRELATED_KEY": "keep"]
        let anonymous = config.engineEnvironment(inheriting: inherited, modelKey: nil)
        #expect(anonymous["CUSTOM_MODEL_KEY"] == nil && anonymous["UNRELATED_KEY"] == "keep")
        let keyed = config.engineEnvironment(inheriting: inherited, modelKey: "new-custom-key")
        #expect(keyed["CUSTOM_MODEL_KEY"] == "new-custom-key")
    }
}
