import Testing
@testable import Tact

struct ReasoningCapabilitiesTests {
    @Test func claudeOffersEffortFirstAndBudgetWhateverTheModel() throws {
        #expect(ReasoningCapabilities.formats(provider: "anthropic") == ["anthropic_effort", "anthropic_budget"])
        let effort = try #require(ReasoningCapabilities.knownProfile(provider: "custom", protocol: .anthropic))
        #expect(effort.format == "anthropic_effort")
        #expect(effort.efforts == ["", "none", "low", "medium", "high", "xhigh", "max"])
        #expect(effort.thinkingType(for: "low") == "adaptive")
        #expect(effort.thinkingType(for: "none") == "disabled")
        let budget = try #require(ReasoningCapabilities.profile(provider: "anthropic", format: "anthropic_budget"))
        #expect(budget.budgetRange == 1024...32768)
        #expect(budget.thinkingType(for: "enabled") == "enabled")
        #expect(!budget.allowsDynamicBudget)
    }

    @Test func geminiOffersLevelsFirstAndADynamicBudget() throws {
        #expect(ReasoningCapabilities.formats(provider: "gemini") == ["gemini_level", "gemini_budget"])
        let level = try #require(ReasoningCapabilities.knownProfile(provider: "custom", protocol: .gemini))
        #expect(level.efforts == ["", "minimal", "low", "medium", "high"])
        #expect(!level.efforts.contains("none"))
        let budget = try #require(ReasoningCapabilities.profile(provider: "gemini", format: "gemini_budget"))
        #expect(budget.efforts.contains("none") && budget.allowsDynamicBudget)
        #expect(ReasoningCapabilities.profile(provider: "gemini", format: "anthropic_effort") == nil)
    }

    @Test func theModelListOverridesTheProtocolDefaults() throws {
        let budgetOnly = RemoteModelCapabilities(reasoningSupported: true, reasoningFormat: "anthropic_budget",
                                                 thinkingTypes: ["enabled", "disabled"], canDisable: true)
        let budget = try #require(ReasoningCapabilities.resolving(
            budgetOnly, fallback: ReasoningCapabilities.profile(provider: "anthropic", format: "anthropic_budget"), protocol: .anthropic))
        #expect(budget.format == "anthropic_budget" && budget.efforts == ["", "none", "enabled"])
        #expect(budget.budgetRange == 1024...32768 && budget.thinkingType(for: "enabled") == "enabled")

        let alwaysThinks = RemoteModelCapabilities(reasoningSupported: true, reasoningFormat: "anthropic_effort",
                                                   effortLevels: ["low", "medium", "high", "xhigh", "max"],
                                                   thinkingTypes: ["adaptive"], canDisable: false)
        let effort = try #require(ReasoningCapabilities.resolving(
            alwaysThinks, fallback: ReasoningCapabilities.knownProfile(provider: "anthropic", protocol: .anthropic), protocol: .anthropic))
        #expect(effort.efforts == ["", "low", "medium", "high", "xhigh", "max"])
    }

    @Test func otherProvidersHaveNoNativeFamilies() {
        #expect(ReasoningCapabilities.formats(provider: "local").isEmpty)
        #expect(ReasoningCapabilities.formats(provider: "zhipu").isEmpty)
        #expect(ReasoningCapabilities.profile(provider: "openai", format: "anthropic_effort") == nil)
    }

    @Test func customEndpointsRequireExplicitParameterFamily() throws {
        let formats = ReasoningCapabilities.formats(provider: "custom")
        #expect(Set(formats) == Set(["openai", "deepseek", "reasoning", "anthropic_effort", "anthropic_budget", "gemini_level", "gemini_budget"]))
        #expect(ReasoningCapabilities.profile(provider: "custom", format: "") == nil)
        let deepseek = try #require(ReasoningCapabilities.profile(provider: "custom", format: "deepseek"))
        #expect(deepseek.efforts == ["", "none", "low", "high", "max"])
        let gemini = try #require(ReasoningCapabilities.profile(provider: "custom", format: "gemini_level"))
        #expect(!gemini.efforts.contains("none"))
    }
}
