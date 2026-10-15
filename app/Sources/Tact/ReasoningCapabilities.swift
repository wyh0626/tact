import Foundation

/// Controls of one request parameter family. Which of them a particular model
/// accepts comes from the provider's model list when it says so; otherwise
/// the model's API answers a control it does not support with an error.
struct ReasoningCapability: Equatable {
    let format: String
    let efforts: [String]
    let budgetRange: ClosedRange<Int>?
    let defaultBudget: Int
    let thinkingType: String?
    let disabledThinkingType: String?
    let allowsDynamicBudget: Bool
    let detail: String

    var usesBudget: Bool { budgetRange != nil || format == "anthropic_budget" || format == "gemini_budget" }

    func thinkingType(for effort: String) -> String? {
        effort == "none" ? disabledThinkingType : thinkingType
    }
}

enum ReasoningCapabilities {
    // Parameter families as each API documents them, never per model ID:
    // https://platform.claude.com/docs/en/build-with-claude/effort
    // https://ai.google.dev/gemini-api/docs/generate-content/thinking
    static func formats(provider: String) -> [String] {
        profiles(provider: provider).map(\.format)
    }

    static func profile(provider: String, format: String) -> ReasoningCapability? {
        profiles(provider: provider).first { $0.format == format }
    }

    /// The family a preset's API uses for every model. A provider whose models
    /// use different families, and an arbitrary OpenAI-compatible gateway, has
    /// none: its controls come from the model list or advanced settings.
    static func knownProfile(provider: String, protocol apiProtocol: ModelProtocol) -> ReasoningCapability? {
        let profile = knownProviderProfile(provider: provider, protocol: apiProtocol)
        if apiProtocol == .responses, let profile, !["openai", "reasoning"].contains(profile.format) { return nil }
        return profile
    }

    private static func knownProviderProfile(provider: String, protocol apiProtocol: ModelProtocol) -> ReasoningCapability? {
        if apiProtocol == .anthropic { return claudeProfiles().first }
        if apiProtocol == .gemini { return geminiProfiles().first }
        let detail = L10n.tr("接口未返回模型能力时显示此服务商的通用档位；模型不支持的档位会由接口报错。",
                             "Shows this provider's standard levels when the API reports no model capabilities; the API reports levels a model does not support.")
        switch provider {
        case "deepseek": return levels("deepseek", values: ["none", "low", "high", "max"], detail: detail)
        case "openai": return levels("openai", values: ["low", "medium", "high"], detail: detail)
        case "qwen": return levels("qwen", values: ["none", "enabled"], detail: detail)
        default: return nil
        }
    }

    /// API fields override only the fields actually reported. Explicit false
    /// and an explicit empty effort list are authoritative.
    static func resolving(_ remote: RemoteModelCapabilities?, fallback: ReasoningCapability?,
                          protocol apiProtocol: ModelProtocol) -> ReasoningCapability? {
        guard let remote, remote.hasReasoningInformation else { return fallback }
        if remote.reasoningSupported == false { return nil }
        let format = remote.reasoningFormat ?? fallback?.format ??
            (apiProtocol == .anthropic ? "anthropic_effort" : apiProtocol == .gemini ? "gemini_level" : "openai")
        let supported: [String: [String]] = [
            "openai": ["none", "minimal", "low", "medium", "high", "xhigh", "max"],
            "deepseek": ["none", "low", "high", "max"],
            "reasoning": ["none", "minimal", "low", "medium", "high", "xhigh", "max"],
            "thinking": ["none", "enabled", "adaptive", "auto"], "qwen": ["none", "enabled"], "siliconflow": ["none", "enabled"],
            "anthropic_effort": ["none", "low", "medium", "high", "xhigh", "max"], "anthropic_budget": ["none", "enabled"],
            "gemini_level": ["minimal", "low", "medium", "high"], "gemini_budget": ["none", "enabled"],
        ]
        guard let allowed = supported[format] else { return nil }
        if apiProtocol == .anthropic && !format.hasPrefix("anthropic_") { return nil }
        if apiProtocol == .gemini && !format.hasPrefix("gemini_") { return nil }
        if apiProtocol == .responses && !["openai", "reasoning"].contains(format) { return nil }
        let sameFamily = fallback?.format == format ? fallback : nil
        var efforts = remote.effortLevels.map { [""] + $0.filter { !$0.isEmpty } } ?? sameFamily?.efforts ?? [""]
        efforts = efforts.filter { $0.isEmpty || allowed.contains($0) }
        if let types = remote.thinkingTypes, remote.effortLevels == nil,
           types.contains("enabled"), !types.contains("adaptive"), format != "anthropic_budget" {
            efforts = ["", "enabled"]
        }
        if remote.canDisable == true && !efforts.contains("none") { efforts.insert("none", at: 1) }
        if remote.canDisable == false { efforts.removeAll { $0 == "none" } }
        let lower = remote.budgetMin ?? sameFamily?.budgetRange?.lowerBound
        let upper = remote.budgetMax ?? sameFamily?.budgetRange?.upperBound
        let range: ClosedRange<Int>? = lower.flatMap { minimum in
            upper.flatMap { maximum in minimum <= maximum ? minimum...maximum : nil }
        }
        if (range != nil && remote.effortLevels == nil || format == "anthropic_budget" || format == "gemini_budget") && !efforts.contains("enabled") { efforts.append("enabled") }
        let types = remote.thinkingTypes
        let type = types.map { $0.contains("adaptive") ? "adaptive" : $0.contains("enabled") ? "enabled" : nil } ?? sameFamily?.thinkingType
        let disabled = remote.canDisable == false ? nil :
            types.map { $0.contains("disabled") ? "disabled" : $0.contains("between_tools") ? "between_tools" : nil } ?? sameFamily?.disabledThinkingType
        return ReasoningCapability(format: format, efforts: Array(NSOrderedSet(array: efforts)) as? [String] ?? efforts,
            budgetRange: range, defaultBudget: range.map { min(max(2048, $0.lowerBound), $0.upperBound) } ?? 2048,
            thinkingType: type, disabledThinkingType: disabled,
            allowsDynamicBudget: sameFamily?.allowsDynamicBudget ?? false,
            detail: L10n.tr("优先使用接口返回的模型能力；未返回的字段使用此服务商的通用档位。", "API-reported model capabilities take priority; missing fields use this provider's standard levels."))
    }

    private static func profiles(provider: String) -> [ReasoningCapability] {
        switch provider {
        case "anthropic": return claudeProfiles()
        case "gemini": return geminiProfiles()
        case "custom": return customProfiles()
        default: return []
        }
    }

    private static func claudeProfiles() -> [ReasoningCapability] {
        [levels("anthropic_effort", values: ["low", "medium", "high", "xhigh", "max"], disabledType: "disabled",
                detail: L10n.tr("由模型自动决定思考量，档位越高通常越慢。", "The model chooses how much to think; higher effort is usually slower.")),
         budget("anthropic_budget", range: 1024...32768, disabled: true, type: "enabled",
                detail: L10n.tr("Tact 支持 1,024–32,768 token 的思考预算，并为最终回复保留输出空间。", "Tact supports thinking budgets of 1,024–32,768 tokens and leaves output space for the final reply."))]
    }

    private static func geminiProfiles() -> [ReasoningCapability] {
        [levels("gemini_level", values: ["minimal", "low", "medium", "high"],
                detail: L10n.tr("按模型支持的档位控制思考；最低档不保证完全关闭思考。", "Use the model's supported thinking levels; the lowest level does not guarantee thinking is off.")),
         budget("gemini_budget", range: 1...32768, disabled: true, dynamic: true,
                detail: L10n.tr("思考预算以 token 计；-1 表示由模型动态分配。", "Thinking budget is in tokens; -1 lets the model allocate it dynamically."))]
    }

    private static func customProfiles() -> [ReasoningCapability] {
        let detail = L10n.tr("选择接口文档声明的参数格式和档位；可用值由接口及模型决定。", "Choose the parameter format and levels documented by your endpoint; support depends on the endpoint and model.")
        return [levels("openai", values: ["none", "minimal", "low", "medium", "high", "xhigh", "max"], detail: detail),
                levels("deepseek", values: ["none", "low", "high", "max"], detail: detail),
                levels("reasoning", values: ["none", "minimal", "low", "medium", "high", "xhigh"], detail: detail),
                levels("anthropic_effort", values: ["low", "medium", "high", "xhigh", "max"], disabledType: "disabled", detail: detail),
                budget("anthropic_budget", range: 1024...32768, disabled: true, type: "enabled", detail: detail),
                levels("gemini_level", values: ["minimal", "low", "medium", "high"], detail: detail),
                budget("gemini_budget", range: 1...32768, disabled: true, dynamic: true, detail: detail)]
    }

    private static func levels(_ format: String, values: [String], disabledType: String? = nil,
                               detail: String) -> ReasoningCapability {
        ReasoningCapability(format: format, efforts: [""] + (disabledType == nil ? [] : ["none"]) + values,
                            budgetRange: nil, defaultBudget: 2048,
                            thinkingType: format == "anthropic_effort" ? "adaptive" : nil,
                            disabledThinkingType: disabledType, allowsDynamicBudget: false, detail: detail)
    }

    private static func budget(_ format: String, range: ClosedRange<Int>, disabled: Bool,
                               dynamic: Bool = false, type: String? = nil, detail: String) -> ReasoningCapability {
        ReasoningCapability(format: format, efforts: [""] + (disabled ? ["none"] : []) + ["enabled"],
                            budgetRange: range, defaultBudget: 2048, thinkingType: type,
                            disabledThinkingType: type == "enabled" ? "disabled" : nil,
                            allowsDynamicBudget: dynamic, detail: detail)
    }
}
