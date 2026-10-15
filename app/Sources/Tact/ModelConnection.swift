import Foundation

/// Metadata reported by a model-list API. Missing fields remain unknown.
struct RemoteModelCapabilities: Hashable {
    var reasoningSupported: Bool?
    var reasoningFormat: String?
    var effortLevels: [String]?
    var thinkingTypes: [String]?
    var canDisable: Bool?
    var budgetMin: Int?
    var budgetMax: Int?
    var maxOutputTokens: Int?

    init(reasoningSupported: Bool? = nil, reasoningFormat: String? = nil, effortLevels: [String]? = nil,
         thinkingTypes: [String]? = nil, canDisable: Bool? = nil, budgetMin: Int? = nil,
         budgetMax: Int? = nil, maxOutputTokens: Int? = nil) {
        self.reasoningSupported = reasoningSupported
        self.reasoningFormat = reasoningFormat
        self.effortLevels = effortLevels
        self.thinkingTypes = thinkingTypes
        self.canDisable = canDisable
        self.budgetMin = budgetMin
        self.budgetMax = budgetMax
        self.maxOutputTokens = maxOutputTokens
    }

    init(_ raw: [String: Any]) {
        reasoningSupported = raw["reasoning_supported"] as? Bool
        reasoningFormat = raw["reasoning_format"] as? String
        effortLevels = raw["effort_levels"] as? [String]
        thinkingTypes = raw["thinking_types"] as? [String]
        canDisable = raw["can_disable"] as? Bool
        budgetMin = (raw["budget_min"] as? NSNumber)?.intValue
        budgetMax = (raw["budget_max"] as? NSNumber)?.intValue
        maxOutputTokens = (raw["max_output_tokens"] as? NSNumber)?.intValue
    }

    var hasReasoningInformation: Bool {
        reasoningSupported != nil || reasoningFormat != nil || effortLevels != nil || thinkingTypes != nil ||
            canDisable != nil || budgetMin != nil || budgetMax != nil
    }
}

struct RemoteModel: Identifiable, Hashable {
    let id: String
    let name: String
    let capabilities: RemoteModelCapabilities?

    init(id: String, name: String? = nil, capabilities: RemoteModelCapabilities? = nil) {
        self.id = id
        self.name = name ?? id
        self.capabilities = capabilities
    }

    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, name: raw["name"] as? String,
                  capabilities: (raw["capabilities"] as? [String: Any]).map(RemoteModelCapabilities.init))
    }
}

/// Identifies a catalog request without writing credentials to disk or logs.
struct ModelConnectionIdentity: Equatable {
    let provider: String
    let protocolID: String
    let baseURL: String
    let typedKey: String
    let headers: String
}

/// The last API-reported capabilities for the selected model. The identity
/// contains connection settings and a digest of headers, never an API key.
struct ModelCapabilitySnapshot {
    let modelID: String
    let provider: String
    let protocolID: String
    let baseURL: String
    let keyAccount: String
    let headersDigest: String
    let capabilities: RemoteModelCapabilities

    init(modelID: String, provider: String, protocolID: String, baseURL: String,
         keyAccount: String, headersDigest: String, capabilities: RemoteModelCapabilities) {
        self.modelID = modelID
        self.provider = provider
        self.protocolID = protocolID
        self.baseURL = baseURL
        self.keyAccount = keyAccount
        self.headersDigest = headersDigest
        self.capabilities = capabilities
    }

    init?(_ raw: [String: Any]) {
        guard let modelID = raw["model"] as? String, let provider = raw["provider"] as? String,
              let protocolID = raw["protocol"] as? String, let baseURL = raw["base_url"] as? String,
              let keyAccount = raw["api_key_account"] as? String, let headersDigest = raw["headers_digest"] as? String,
              let capabilities = raw["capabilities"] as? [String: Any] else { return nil }
        self.init(modelID: modelID, provider: provider, protocolID: protocolID, baseURL: baseURL,
                  keyAccount: keyAccount, headersDigest: headersDigest, capabilities: RemoteModelCapabilities(capabilities))
    }

    var jsonObject: [String: Any] {
        ["model": modelID, "provider": provider, "protocol": protocolID, "base_url": baseURL,
         "api_key_account": keyAccount, "headers_digest": headersDigest, "capabilities": capabilities.jsonObject]
    }
}

extension RemoteModelCapabilities {
    var jsonObject: [String: Any] {
        var result: [String: Any] = ["source": "api"]
        result["reasoning_supported"] = reasoningSupported
        result["reasoning_format"] = reasoningFormat
        result["effort_levels"] = effortLevels
        result["thinking_types"] = thinkingTypes
        result["can_disable"] = canDisable
        result["budget_min"] = budgetMin
        result["budget_max"] = budgetMax
        result["max_output_tokens"] = maxOutputTokens
        return result
    }
}
