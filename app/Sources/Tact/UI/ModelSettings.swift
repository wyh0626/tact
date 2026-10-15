import AppKit
import CryptoKit

/// The model part of the configuration, shared by onboarding and settings.
@MainActor
final class ModelSettings: ObservableObject {
    enum TestState: Equatable {
        case idle
        case testing
        case passed(String)
        case failed(String)
    }

    @Published var provider: ModelProvider
    /// Keep legacy OpenAI-compatible configs on their saved protocol until
    /// the user explicitly chooses a provider.
    private var configuredProvider: String?
    @Published var apiProtocol: ModelProtocol {
        didSet {
            guard oldValue != apiProtocol else { return }
            protocolChangedByUser = true
            invalidateModelCatalog()
            reconcileSpeed()
        }
    }
    private var protocolChangedByUser = false
    @Published var baseURL: String {
        didSet {
            if oldValue != baseURL {
                if let oldOrigin = ModelKeyScope.origin(of: oldValue), ModelKeyScope.origin(of: baseURL) != oldOrigin {
                    apiKey = ""
                    headersJSON = "{}"
                }
                invalidateModelCatalog()
            }
        }
    }
    @Published var model: String
    /// A newly typed key; empty keeps the one already in the keychain.
    @Published var apiKey = "" {
        didSet {
            if oldValue != apiKey {
                if !apiKey.isEmpty { capabilitySnapshot = nil }
                invalidateModelCatalog()
            }
        }
    }
    @Published var extraBodyJSON: String {
        didSet {
            if Self.reasoningFields(in: oldValue) != Self.reasoningFields(in: extraBodyJSON) {
                advancedReasoningOverridesControls = true
            }
        }
    }
    private var advancedReasoningOverridesControls = false
    @Published var headersJSON: String { didSet { if oldValue != headersJSON { invalidateModelCatalog() } } }
    private let loadedExtraBodyJSON: String
    private let loadedHeadersJSON: String
    @Published var maxTokens: Int
    @Published var timeoutMS: Int
    private let loadedMaxTokens: Int
    private let loadedTimeoutMS: Int
    private let loadedKeyAccount: String
    private let loadedOrigin: String?
    private let loadedProtocol: ModelProtocol
    @Published private(set) var availableModels: [RemoteModel] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelLoadMessage: String?
    @Published private(set) var modelLoadError: String?
    private var catalogIdentity: ModelConnectionIdentity?
    private var catalogGeneration = 0
    private var capabilitySnapshot: ModelCapabilitySnapshot?
    @Published private(set) var hasStoredKey: Bool
    /// Reasoning effort to request; "" leaves the model's default, and for
    /// DeepSeek "none" means thinking off.
    @Published var reasoningEffort: String {
        didSet { if oldValue != reasoningEffort && !suppressReasoningChanges { reasoningChanged = true; advancedReasoningOverridesControls = false } }
    }
    /// The wire parameter family explicitly selected for native/custom APIs.
    @Published var reasoningFormat: String {
        didSet { if oldValue != reasoningFormat && !suppressReasoningChanges { reasoningChanged = true; advancedReasoningOverridesControls = false } }
    }
    @Published var thinkingBudget: Int {
        didSet { if oldValue != thinkingBudget && !suppressReasoningChanges { reasoningChanged = true; advancedReasoningOverridesControls = false } }
    }
    /// Ask for the provider's Fast tier.
    @Published var fastMode: Bool {
        didSet { if oldValue != fastMode && !suppressReasoningChanges { fastModeChanged = true } }
    }
    private var reasoningChanged = false
    private var fastModeChanged = false
    private var providerChanged = false
    private var suppressReasoningChanges = false
    private let loadedProvider: ModelProvider
    private let loadedModel: String
    @Published var testState = TestState.idle
    /// The local model chosen in the list; it takes effect once saved.
    @Published var localModelID: String
    /// The local model the saved configuration runs, if any.
    @Published private(set) var savedLocalModelID: String?
    let localStore: LocalModelStore

    // ChatGPT sign-in, read from the engine, which owns the session.
    @Published var chatgpt: ChatGPTStatus?
    @Published var chatgptModels: [ChatGPTModel] = []
    @Published var chatgptMessage: String?
    /// "You're using your ChatGPT plan" is shown once, after the first sign-in.
    @Published var showPlanWelcome = false
    static let planWelcomeKey = "chatgpt.planWelcomeShown"

    init(file: ConfigFile, localStore: LocalModelStore? = nil) {
        self.localStore = localStore ?? .shared
        let saved = (file.string("model.local.path") as NSString?)?.lastPathComponent
        let savedModel = LocalModel.catalog.first { $0.file == saved }
        localModelID = savedModel?.id ?? LocalModel.recommended(forMemoryGB: LocalModelStore.memoryGB).id
        savedLocalModelID = file.string("model.provider") == "local" ? savedModel?.id : nil
        let base = file.string("model.base_url") ?? ""
        let matched = ModelProvider.matching(provider: file.string("model.provider"), baseURL: base)
        provider = matched
        configuredProvider = file.string("model.provider")
        let savedProtocol = ModelProtocol.resolved(file.string("model.protocol"), provider: matched)
        apiProtocol = savedProtocol
        loadedProtocol = savedProtocol
        loadedOrigin = ModelKeyScope.origin(of: base)
        loadedKeyAccount = file.string("model.api_key_account").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? Keychain.modelKey
        let savedMax = Int(file.number("model.max_tokens") ?? 300)
        maxTokens = savedMax
        loadedMaxTokens = savedMax
        let savedTimeout = Int(file.number("model.timeout_ms") ?? 20000)
        timeoutMS = savedTimeout
        loadedTimeoutMS = savedTimeout
        let extraJSON = Self.jsonText(file.value("model.extra_body"))
        extraBodyJSON = extraJSON
        loadedExtraBodyJSON = extraJSON
        let headerJSON = Self.jsonText(file.value("model.headers"))
        headersJSON = headerJSON
        loadedHeadersJSON = headerJSON
        baseURL = base
        model = file.string("model.model") ?? ""
        hasStoredKey = !(Keychain.read(file.string("model.api_key_account").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? Keychain.modelKey) ?? "").isEmpty
        loadedProvider = matched
        loadedModel = file.string("model.model") ?? ""
        let savedReasoning = Self.readReasoning(file, provider: matched, protocol: savedProtocol)
        reasoningFormat = savedReasoning.format
        reasoningEffort = savedReasoning.effort
        thinkingBudget = savedReasoning.budget
        fastMode = !(file.string("model.service_tier") ?? "").isEmpty
        capabilitySnapshot = (file.value("model.capability_cache") as? [String: Any]).flatMap(ModelCapabilitySnapshot.init)
    }

    var usesOpenAI: Bool { provider.cardID == ModelProvider.openai.id }

    /// The default model when the account offers it, else its first one.
    var preferredChatGPTModel: String {
        let preferred = ModelProvider.chatgpt.defaultModel
        return chatgptModels.contains { $0.slug == preferred } ? preferred : chatgptModels.first?.slug ?? ""
    }

    /// Picking the OpenAI card starts on ChatGPT sign-in, which needs no key;
    /// picking the card already chosen keeps its sign-in method.
    func chooseCard(_ card: ModelProvider) {
        guard provider.cardID != card.id else { return }
        choose(card.id == ModelProvider.openai.id ? .chatgpt : card)
        if card == .local { prepareLocalModel() }
    }

    /// Picks a model for the local card: one already downloaded, or else
    /// the recommended one, which downloads only when asked.
    func prepareLocalModel() {
        if let chosen = localModel, localStore.isReady(chosen) { return }
        let recommended = LocalModel.recommended(forMemoryGB: LocalModelStore.memoryGB)
        useLocalModel(([recommended] + LocalModel.catalog).first(where: localStore.isReady) ?? recommended)
    }

    func choose(_ preset: ModelProvider) {
        let previous = provider
        if preset != previous {
            // A freshly typed key or custom header may belong only to the
            // previous connection. Keep saved scoped keys in the keychain.
            apiKey = ""
            headersJSON = "{}"
        }
        provider = preset
        configuredProvider = preset.configurationValue
        apiProtocol = preset.defaultProtocol
        invalidateModelCatalog()
        providerChanged = providerChanged || preset != previous
        if !preset.baseURL.isEmpty || preset == .local { baseURL = preset.baseURL }
        if preset != previous && !preset.usesSignIn && preset != .local {
            maxTokens = 4096
            timeoutMS = 60000
        }
        if preset == .local {
            model = localModelID
        } else if preset.usesSignIn {
            // Models come from the signed-in account's list.
            if !chatgptModels.contains(where: { $0.slug == model }) { model = preferredChatGPTModel }
        } else if preset != previous {
            // A model name means nothing to another provider.
            model = preset.defaultModel
        }
        reasoningFormat = Self.defaultReasoningFormat(provider: preset)
        reasoningEffort = preset.speed == .deepseek ? "none" : preset.speed == .openai ? "low" : ""
        thinkingBudget = reasoningCapability?.defaultBudget ?? 1024
        reasoningChanged = true
        fastMode = false
        testState = .idle
    }

    // MARK: - Speed

    private var snapshotMatchesConnection: Bool {
        guard let snapshot = capabilitySnapshot else { return false }
        return snapshot.modelID == model && snapshot.provider == (configuredProvider ?? "") &&
            snapshot.protocolID == apiProtocol.rawValue && snapshot.baseURL == baseURL.trimmingCharacters(in: .whitespacesAndNewlines) &&
            snapshot.keyAccount == currentKeyAccount && snapshot.headersDigest == headersFingerprint
    }

    private var usesCapabilitySnapshot: Bool {
        catalogIdentity != connectionIdentity && snapshotMatchesConnection
    }

    private var remoteCapabilities: RemoteModelCapabilities? {
        if catalogIdentity == connectionIdentity { return availableModels.first { $0.id == model }?.capabilities }
        return snapshotMatchesConnection ? capabilitySnapshot?.capabilities : nil
    }

    private var headersFingerprint: String {
        let object = Self.jsonObject(headersJSON) ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var reasoningCapability: ReasoningCapability? {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fallback = ReasoningCapabilities.knownProfile(provider: provider.id, protocol: apiProtocol)
        // A legacy explicit family remains editable only when it already exists;
        // new unknown endpoints rely on API metadata or advanced raw parameters.
        let legacyProvider = apiProtocol == .anthropic ? "anthropic" : apiProtocol == .gemini ? "gemini" : provider.id
        let legacy = provider == .custom && (apiProtocol == .openai || apiProtocol == .responses) ? nil :
            ReasoningCapabilities.profile(provider: legacyProvider, format: reasoningFormat)
        let legacyFamilyMatchesProtocol: Bool
        switch apiProtocol {
        case .anthropic: legacyFamilyMatchesProtocol = reasoningFormat.hasPrefix("anthropic_")
        case .gemini: legacyFamilyMatchesProtocol = reasoningFormat.hasPrefix("gemini_")
        case .responses: legacyFamilyMatchesProtocol = ["openai", "reasoning"].contains(reasoningFormat)
        case .openai: legacyFamilyMatchesProtocol = true
        }
        var selected = fallback?.format == reasoningFormat || reasoningFormat.isEmpty ? fallback :
            (provider == loadedProvider && model == loadedModel && apiProtocol == loadedProtocol && legacyFamilyMatchesProtocol ? legacy : fallback)
        if let apiFormat = remoteCapabilities?.reasoningFormat {
            let nativeProvider = apiProtocol == .anthropic ? "anthropic" : apiProtocol == .gemini ? "gemini" : provider.id
            selected = ReasoningCapabilities.profile(provider: nativeProvider, format: apiFormat) ?? selected
        }
        return ReasoningCapabilities.resolving(remoteCapabilities, fallback: selected, protocol: apiProtocol)
    }

    var usesThinkingBudget: Bool { reasoningCapability?.usesBudget == true }

    var reasoningCapabilitySource: String {
        if let remote = remoteCapabilities, remote.hasReasoningInformation {
            let local = ReasoningCapabilities.knownProfile(provider: provider.id, protocol: apiProtocol)
            let supplemented = remote.reasoningSupported != false && local != nil &&
                (remote.effortLevels == nil || (local?.usesBudget == true && (remote.budgetMin == nil || remote.budgetMax == nil)) ||
                 (local?.thinkingType != nil && remote.thinkingTypes == nil))
            if usesCapabilitySnapshot {
                return supplemented ? L10n.tr("上次接口返回，通用档位补充", "Last API response, supplemented by standard levels") : L10n.tr("上次接口返回", "Last API response")
            }
            return supplemented ? L10n.tr("接口优先，通用档位补充", "API first, supplemented by standard levels") : L10n.tr("接口返回", "Reported by API")
        }
        if reasoningCapability != nil { return L10n.tr("服务商通用档位", "Provider standard levels") }
        return L10n.tr("能力未知", "Capabilities unknown")
    }

    var reasoningDetail: String {
        if remoteCapabilities?.reasoningSupported == false {
            return L10n.tr("接口声明此模型不支持推理控制，使用模型默认。", "The API reports that this model has no reasoning controls; model defaults apply.")
        }
        if let capability = reasoningCapability { return capability.detail }
        return L10n.tr("接口尚未提供此模型的推理能力信息。使用模型默认；特殊参数可在高级设置中填写，已有配置会保留。", "No reasoning capabilities are available for this model. Model defaults apply; advanced settings accept custom parameters and preserve existing configuration.")
    }

    var usesAdvancedReasoningParameters: Bool { advancedReasoningOverridesControls }

    var reasoningValidationError: String? {
        guard !advancedReasoningOverridesControls, !provider.usesSignIn, provider != .local, reasoningChanged, !reasoningFormat.isEmpty else { return nil }
        guard let capability = reasoningCapability else {
            if reasoningEffort.isEmpty { return nil }
            return L10n.tr("这个模型不支持所选的推理参数格式", "This model does not support the selected reasoning parameter format")
        }
        guard capability.efforts.contains(reasoningEffort) else {
            return L10n.tr("这个模型不支持所选的推理程度", "This model does not support the selected reasoning level")
        }
        if capability.usesBudget && reasoningEffort == "enabled" {
            if thinkingBudget > Int(Int32.max) || capability.format == "anthropic_budget" && thinkingBudget < 1024 ||
                capability.format == "gemini_budget" && (thinkingBudget == 0 || thinkingBudget < -1) {
                return L10n.tr("思考预算不符合此接口的参数范围", "Thinking budget is outside this protocol's supported range")
            }
        }
        if capability.usesBudget && reasoningEffort == "enabled", let range = capability.budgetRange,
           !range.contains(thinkingBudget), !(capability.allowsDynamicBudget && thinkingBudget == -1) {
            return L10n.tr("思考预算应在 \(range.lowerBound)–\(range.upperBound) token 之间", "Thinking budget must be between \(range.lowerBound) and \(range.upperBound) tokens")
        }
        return nil
    }

    var speedOptions: SpeedOptions {
        if !provider.usesSignIn {
            guard provider != .local, let capability = reasoningCapability else { return SpeedOptions(levels: [], fastTier: nil) }
            return SpeedOptions(levels: capability.efforts.map { effort in
                if effort == "none", capability.disabledThinkingType == "between_tools" {
                    return .init(effort: effort, label: L10n.tr("最低", "Minimum"),
                                 detail: L10n.tr("关闭回复前思考；工具调用之间仍可思考", "Skips up-front thinking; thinking between tool calls remains possible."))
                }
                return .init(effort: effort, label: SpeedOptions.label(for: effort), detail: SpeedOptions.detail(for: effort))
            }, fastTier: provider.speed == .openai ? .init(id: "priority", detail: L10n.tr("更快出结果，按更高的价格计费", "Faster results at a higher price.")) : nil, preferred: "")
        }
        guard let selected = chatgptModels.first(where: { $0.slug == model }) else {
            return SpeedOptions(levels: [], fastTier: nil)
        }
        let tier = selected.speedTiers.first.map {
            SpeedOptions.FastTier(id: $0.id, detail: SpeedOptions.tierDetail($0.description))
        }
        // Drafting a chat reply never needs the deepest levels, which
        // take far longer; one level left is no choice at all.
        let offered = Set(selected.reasoningLevels.map(\.effort))
        let useful = SpeedOptions.replyEfforts.filter(offered.contains)
        guard useful.count >= 2 else { return SpeedOptions(levels: [], fastTier: tier) }
        let levels = useful.map { effort in
            let detail = SpeedOptions.detail(for: effort)
            return SpeedOptions.Level(effort: effort, label: SpeedOptions.label(for: effort),
                                      detail: effort == selected.defaultReasoning ? L10n.tr("模型默认。", "Model default. ") + detail : detail)
        }
        let preferred = useful.contains(selected.defaultReasoning ?? "") ? selected.defaultReasoning
            : useful.contains("low") ? "low" : useful.first
        return SpeedOptions(levels: levels, fastTier: tier, preferred: preferred)
    }

    /// Keeps the choice valid after the model changes: an effort the new
    /// model lacks falls back to its default, no levels means the model's
    /// own default, and Fast goes off without a tier.
    func reconcileSpeed() {
        // Opening settings can reconcile account metadata without changing the
        // saved raw parameters. An actual model/control edit is persisted.
        let preserveLoadedReasoning = !reasoningChanged && provider == loadedProvider && model == loadedModel
        let previousSuppression = suppressReasoningChanges
        let rawOverride = advancedReasoningOverridesControls
        suppressReasoningChanges = preserveLoadedReasoning
        defer {
            suppressReasoningChanges = previousSuppression
            advancedReasoningOverridesControls = rawOverride
        }
        if !provider.usesSignIn && provider != .local {
            if let capability = reasoningCapability {
                reasoningFormat = capability.format
            } else if !preserveLoadedReasoning && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Without a model there is nothing to check the choice against yet.
                reasoningFormat = ""
                reasoningEffort = ""
            }
            if let capability = reasoningCapability {
                if !capability.efforts.contains(reasoningEffort) { reasoningEffort = "" }
                if let range = capability.budgetRange, !range.contains(thinkingBudget),
                   !(capability.allowsDynamicBudget && thinkingBudget == -1) {
                    thinkingBudget = capability.defaultBudget
                }
            }
            if speedOptions.fastTier == nil { fastMode = false }
            return
        }
        let options = speedOptions
        if options.levels.isEmpty {
            if provider.speed == .chatgpt { reasoningEffort = "" }
        } else if !options.levels.contains(where: { $0.effort == reasoningEffort }) {
            reasoningEffort = options.preferred ?? options.levels.first?.effort ?? ""
        }
        if options.fastTier == nil { fastMode = false }
    }

    // MARK: - API model catalog and advanced settings

    private var connectionIdentity: ModelConnectionIdentity {
        .init(provider: provider.id, protocolID: apiProtocol.rawValue,
              baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), typedKey: apiKey, headers: headersJSON)
    }

    private func invalidateModelCatalog() {
        catalogGeneration += 1
        catalogIdentity = nil
        availableModels = []
        isLoadingModels = false
        modelLoadMessage = nil
        modelLoadError = nil
        hasStoredKey = !(Keychain.read(currentKeyAccount) ?? "").isEmpty
    }

    var currentKeyAccount: String {
        if provider == loadedProvider && apiProtocol == loadedProtocol && ModelKeyScope.origin(of: baseURL) == loadedOrigin {
            return loadedKeyAccount
        }
        return ModelKeyScope.account(provider: configuredProvider ?? provider.id, protocol: apiProtocol.rawValue, baseURL: baseURL)
    }

    var canUseStoredKey: Bool { hasStoredKey }


    var modelCatalogValidationError: String? {
        if provider.usesSignIn || provider == .local { return nil }
        if ConfigFile.origin(of: baseURL) == nil {
            return L10n.tr("填写有效的接口地址后获取模型", "Enter a valid endpoint before fetching models")
        }
        if keyRequired && apiKey.isEmpty && !canUseStoredKey {
            return L10n.tr("填写此接口的 API Key 后获取模型", "Enter this endpoint's API key before fetching models")
        }
        return headersValidationError
    }

    /// A connection whose key is already saved loads its model list without a
    /// click. A key still being typed is sent only when the user asks.
    var automaticCatalogIdentity: ModelConnectionIdentity? {
        guard hasStoredKey, apiKey.isEmpty, !provider.usesSignIn, provider != .local,
              modelCatalogValidationError == nil, catalogIdentity != connectionIdentity else { return nil }
        return connectionIdentity
    }

    func loadModels(controller: Controller) async {
        await loadModels { request in await controller.engineRequest(request, timeout: 30) }
    }

    /// The injected request closure lets tests exercise out-of-order responses
    /// without network access or a running engine.
    func loadModels(using request: ([String: Any]) async -> [String: Any]?) async {
        if let error = modelCatalogValidationError { modelLoadError = error; return }
        guard !provider.usesSignIn, provider != .local else { return }
        catalogGeneration += 1
        let generation = catalogGeneration
        let identity = connectionIdentity
        isLoadingModels = true
        modelLoadError = nil
        modelLoadMessage = nil
        let requestProvider = !providerChanged && provider == loadedProvider ? (configuredProvider ?? "") : provider.id
        var connection: [String: Any] = ["provider": requestProvider, "protocol": apiProtocol.rawValue,
                                         "base_url": identity.baseURL]
        if !apiKey.isEmpty {
            connection["api_key"] = apiKey
        } else if currentKeyAccount != loadedKeyAccount, let scopedKey = Keychain.read(currentKeyAccount), !scopedKey.isEmpty {
            connection["api_key"] = scopedKey
        }
        if let headers = Self.jsonObject(headersJSON), !headers.isEmpty { connection["headers"] = headers }
        let response = await request(["op": "model_catalog", "connection": connection])
        guard generation == catalogGeneration, identity == connectionIdentity else { return }
        isLoadingModels = false
        guard let response else {
            modelLoadError = L10n.tr("连不上引擎，仍可手动填写模型 ID", "Cannot reach the engine; you can still enter a model ID")
            return
        }
        guard response["ok"] as? Bool == true else {
            modelLoadError = response["error"] as? String ?? L10n.tr("获取模型失败，仍可手动填写", "Could not fetch models; manual entry remains available")
            return
        }
        var seen = Set<String>()
        availableModels = ((response["catalog"] as? [[String: Any]]) ?? []).compactMap(RemoteModel.init)
            .filter { seen.insert($0.id).inserted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        catalogIdentity = identity
        modelLoadMessage = availableModels.isEmpty
            ? L10n.tr("接口没有返回模型列表，请手动填写模型 ID", "The API returned no models; enter a model ID manually")
            : L10n.tr("已获取 \(availableModels.count) 个模型；也可手动填写其他模型 ID", "Fetched \(availableModels.count) models; other model IDs can be entered manually")
        reconcileSpeed()
    }

    var advancedValidationError: String? {
        if maxTokens != loadedMaxTokens && (maxTokens <= 0 || maxTokens > 2_000_000) {
            return L10n.tr("最大输出 token 应在 1–2,000,000 之间", "Maximum output tokens must be between 1 and 2,000,000")
        }
        if timeoutMS != loadedTimeoutMS && !(1000...1_800_000).contains(timeoutMS) {
            return L10n.tr("超时应在 1,000–1,800,000 毫秒之间", "Timeout must be between 1,000 and 1,800,000 milliseconds")
        }
        if Self.jsonObject(extraBodyJSON) == nil {
            return L10n.tr("高级请求参数必须是 JSON 对象", "Advanced request parameters must be a JSON object")
        }
        return headersValidationError
    }

    private var headersValidationError: String? {
        guard let headers = Self.jsonObject(headersJSON), headers.values.allSatisfy({ $0 is String }) else {
            return L10n.tr("请求头必须是值为字符串的 JSON 对象", "Headers must be a JSON object with string values")
        }
        let reserved: Set<String> = ["authorization", "x-api-key", "x-goog-api-key", "content-type", "accept", "host", "connection", "content-length", "transfer-encoding", "proxy-authorization", "trailer", "te", "upgrade", "keep-alive", "proxy-connection", "cookie", "set-cookie"]
        let tokenBytes = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        if headers.keys.contains(where: { reserved.contains($0.lowercased()) || $0.isEmpty || $0.utf8.contains(where: { !tokenBytes.contains($0) }) }) ||
            headers.values.contains(where: { ($0 as? String)?.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) == true }) {
            return L10n.tr("请求头名称和值必须符合 HTTP 格式，且不能覆盖鉴权、内容类型或连接字段", "Header names and values must use valid HTTP syntax and cannot override authentication, content-type or connection fields")
        }
        return nil
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func reasoningFields(in text: String) -> Data? {
        guard let object = jsonObject(text) else { return nil }
        let file = ConfigFile(root: ["extra": object])
        let paths = ["reasoning_effort", "thinking.type", "thinking.budget_tokens", "output_config.effort",
                     "reasoning.effort", "reasoning.enabled", "reasoning.max_tokens", "enable_thinking", "thinking_budget",
                     "generationConfig.thinkingConfig.thinkingLevel", "generationConfig.thinkingConfig.thinkingBudget"]
        var fields: [String: Any] = [:]
        for path in paths { fields[path] = file.value("extra." + path) ?? NSNull() }
        return try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    private static func jsonText(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    var keyRequired: Bool {
        provider.key == .required || provider == .custom && (apiProtocol == .anthropic || apiProtocol == .gemini)
    }

    var localModel: LocalModel? { LocalModel.named(localModelID) }

    /// Picks a downloaded model; saving puts it to use.
    func useLocalModel(_ chosen: LocalModel) {
        localModelID = chosen.id
        if provider == .local { model = chosen.id }
        testState = .idle
    }

    var validationError: String? {
        if provider == .local {
            guard let chosen = localModel else { return L10n.tr("选一个本机模型", "Choose a local model") }
            if !localStore.isReady(chosen) { return L10n.tr("先下载 \(chosen.name)", "Download \(chosen.name) first") }
            return nil
        }
        if provider.usesSignIn {
            guard let status = chatgpt, status.signedIn else { return L10n.tr("先用 ChatGPT 账号登录", "Sign in with ChatGPT first") }
            if !status.planUsage { return L10n.tr("登录时没有授权使用 ChatGPT 套餐，退出后重新登录并允许", "ChatGPT plan usage was not authorized. Sign out, sign in again, and allow plan access.") }
            if model.isEmpty { return L10n.tr("选一个模型", "Choose a model") }
            return nil
        }
        if ConfigFile.origin(of: baseURL) == nil { return L10n.tr("接口地址要以 http:// 或 https:// 开头", "The endpoint URL must start with http:// or https://") }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return L10n.tr("填写模型名", "Enter a model name") }
        if keyRequired && apiKey.isEmpty && !canUseStoredKey { return L10n.tr("填写 API Key", "Enter an API key") }
        return advancedValidationError ?? reasoningValidationError
    }

    func write(into file: inout ConfigFile) {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        let savedProviderID = file.string("model.provider")
        let savedBaseURL = file.string("model.base_url") ?? ""
        let savedProvider = ModelProvider.matching(provider: savedProviderID, baseURL: savedBaseURL)
        let savedProtocol = ModelProtocol.resolved(file.string("model.protocol"), provider: savedProvider)
        let protocolChanged = savedProtocol != apiProtocol
        if (savedProvider != provider && providerChanged) || protocolChanged {
            // Discard the old provider's reasoning fields, keeping unrelated
            // gateway options and response schemas intact.
            Self.clearReasoningFamily(Self.readReasoning(file, provider: savedProvider, protocol: savedProtocol).format, in: &file)
            file.set("model.reasoning", nil)
            file.set("model.reasoning_effort", nil)
            file.set("model.service_tier", nil)
            if apiProtocol == .anthropic { file.set("model.json_mode", nil) }
            if protocolChanged {
                let fields: [String]
                switch savedProtocol {
                case .anthropic: fields = ["thinking", "output_config", "stop_sequences", "top_k"]
                case .gemini: fields = ["generationConfig", "safetySettings", "systemInstruction", "cachedContent", "toolConfig"]
                default: fields = []
                }
                for field in fields { file.set("model.extra_body." + field, nil) }
            }
        }
        file.set("model.provider", configuredProvider)
        if providerChanged || protocolChangedByUser {
            file.set("model.protocol", provider.usesSignIn || provider == .local ? nil : apiProtocol.rawValue)
        }
        // Only replace advanced objects after an intentional editor change.
        // Apply them after protocol cleanup so a newly entered schema survives.
        if extraBodyJSON != loadedExtraBodyJSON, let extra = Self.jsonObject(extraBodyJSON) {
            file.set("model.extra_body", extra.isEmpty ? nil : extra)
        }
        if headersJSON != loadedHeadersJSON, let headers = Self.jsonObject(headersJSON), headers.values.allSatisfy({ $0 is String }) {
            file.set("model.headers", headers.isEmpty ? nil : headers)
        }
        let savedAccount = file.string("model.api_key_account").flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? Keychain.modelKey
        if currentKeyAccount != savedAccount {
            // A setup from before keys were kept per connection has its key in
            // the shared entry, which the new connection does not read. The
            // connection being left gets its own copy, found on the way back.
            if savedAccount == Keychain.modelKey, let shared = Keychain.read(Keychain.modelKey), !shared.isEmpty {
                let previous = ModelKeyScope.account(provider: savedProviderID ?? savedProvider.id,
                                                     protocol: savedProtocol.rawValue, baseURL: savedBaseURL)
                if (Keychain.read(previous) ?? "").isEmpty { Keychain.save(shared, account: previous) }
            }
            file.set("model.api_key_account", currentKeyAccount == Keychain.modelKey ? nil : currentKeyAccount)
        }
        if !provider.usesSignIn && provider != .local {
            if maxTokens != loadedMaxTokens { file.set("model.max_tokens", maxTokens) }
            if timeoutMS != loadedTimeoutMS { file.set("model.timeout_ms", timeoutMS) }
        }
        file.set("model.base_url", base)
        file.set("model.model", model.trimmingCharacters(in: .whitespaces))
        if (file.string("model.api_key_env") ?? "").isEmpty {
            file.set("model.api_key_env", AppConfig.defaultAPIKeyEnv)
        }
        file.allowModelOrigin(of: base)
        writeCapabilitySnapshot(into: &file)
        writeSpeed(into: &file)
        writeLocal(into: &file)
    }

    private func writeCapabilitySnapshot(into file: inout ConfigFile) {
        guard !provider.usesSignIn, provider != .local, let capabilities = remoteCapabilities,
              capabilities.hasReasoningInformation else {
            file.set("model.capability_cache", nil)
            return
        }
        let snapshot = ModelCapabilitySnapshot(modelID: model, provider: configuredProvider ?? "", protocolID: apiProtocol.rawValue,
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines), keyAccount: currentKeyAccount,
            headersDigest: headersFingerprint, capabilities: capabilities)
        capabilitySnapshot = snapshot
        file.set("model.capability_cache", snapshot.jsonObject)
    }

    /// The local model's file and the template option the app owns.
    private func writeLocal(into file: inout ConfigFile) {
        let previouslyLocal = file.string("model.local.path") != nil
        if provider == .local, let chosen = localModel {
            file.set("model.local", ["path": localStore.url(for: chosen).path])
            if chosen.thinks {
                file.set("model.extra_body.chat_template_kwargs.enable_thinking", false)
            } else {
                file.set("model.extra_body.chat_template_kwargs.enable_thinking", nil)
            }
        } else {
            file.set("model.local", nil)
            if previouslyLocal { file.set("model.extra_body.chat_template_kwargs.enable_thinking", nil) }
        }
        Self.pruneEmptyReasoningObjects(in: &file)
    }

    private func writeSpeed(into file: inout ConfigFile) {
        if advancedReasoningOverridesControls {
            // The user's newer raw parameters must not be shadowed by an old
            // typed control saved on a previous visit to settings.
            file.set("model.reasoning", nil)
            file.set("model.reasoning_effort", nil)
            if fastModeChanged {
                file.set("model.service_tier", fastMode ? speedOptions.fastTier?.id : nil)
            }
            return
        }
        if provider.speed == .none && provider != .local || apiProtocol == .anthropic || apiProtocol == .gemini {
            guard reasoningChanged || providerChanged else { return }
            let oldFormat = Self.readReasoning(file, provider: provider, protocol: apiProtocol).format
            if !reasoningFormat.isEmpty && oldFormat != reasoningFormat {
                Self.clearReasoningFamily(oldFormat, in: &file)
            }
            if reasoningFormat.isEmpty {
                file.set("model.reasoning", nil)
            } else {
                var reasoning: [String: Any] = ["format": reasoningFormat, "effort": reasoningEffort]
                let capability = reasoningCapability
                if capability?.usesBudget == true && reasoningEffort == "enabled" {
                    reasoning["budget_tokens"] = thinkingBudget
                }
                if !reasoningEffort.isEmpty, let type = capability?.thinkingType(for: reasoningEffort) {
                    reasoning["thinking_type"] = type
                }
                file.set("model.reasoning", reasoning)
                // A declared custom family takes precedence over the old
                // generic field; the two must not send conflicting requests.
                file.set("model.reasoning_effort", nil)
            }
            Self.pruneEmptyReasoningObjects(in: &file)
            return
        }
        if reasoningChanged || providerChanged {
            file.set("model.reasoning", nil)
            Self.clearReasoningFamily(provider.speed == .deepseek ? "deepseek" : "openai", in: &file)
            file.set("model.reasoning_effort", nil)
            switch provider.speed {
            case .deepseek:
                if reasoningEffort == "none" {
                    file.set("model.extra_body.thinking.type", "disabled")
                } else if !reasoningEffort.isEmpty {
                    file.set("model.reasoning_effort", reasoningEffort)
                }
            case .openai, .chatgpt:
                if !reasoningEffort.isEmpty { file.set("model.reasoning_effort", reasoningEffort) }
            case .none:
                break
            }
        }
        if fastModeChanged || providerChanged {
            file.set("model.service_tier", nil)
            if fastMode, let tier = speedOptions.fastTier { file.set("model.service_tier", tier.id) }
        }
        Self.pruneEmptyReasoningObjects(in: &file)
    }

    private static func defaultReasoningFormat(provider: ModelProvider) -> String {
        switch provider.speed {
        case .deepseek: return "deepseek"
        case .openai: return "openai"
        case .chatgpt: return ""
        case .none:
            return provider == .custom ? "" : ReasoningCapabilities.formats(provider: provider.id).first ?? ""
        }
    }

    /// Read existing raw provider parameters for display without migrating or
    /// deleting them merely because the settings window was opened.
    private static func readReasoning(_ file: ConfigFile, provider: ModelProvider, protocol apiProtocol: ModelProtocol? = nil)
        -> (format: String, effort: String, budget: Int) {
        if let saved = file.value("model.reasoning") as? [String: Any], let format = saved["format"] as? String {
            return (format, saved["effort"] as? String ?? "", (saved["budget_tokens"] as? NSNumber)?.intValue ?? 1024)
        }
        let defaultFormat = ReasoningCapabilities.knownProfile(provider: provider.id, protocol: apiProtocol ?? provider.defaultProtocol)?.format ?? defaultReasoningFormat(provider: provider)
        let defaultBudget = ReasoningCapabilities.profile(provider: provider.id, format: defaultFormat)?.defaultBudget ?? 1024
        let thinkingType = file.string("model.extra_body.thinking.type")
        let genericEffort = file.string("model.reasoning_effort") ?? file.string("model.extra_body.reasoning_effort") ?? ""
        if provider.speed == .deepseek {
            return ("deepseek", thinkingType == "disabled" ? "none" : genericEffort, defaultBudget)
        }
        if provider.speed == .openai || provider.speed == .chatgpt {
            return (defaultFormat, genericEffort, defaultBudget)
        }
        let level = file.string("model.extra_body.generationConfig.thinkingConfig.thinkingLevel")
        let geminiBudget = file.number("model.extra_body.generationConfig.thinkingConfig.thinkingBudget")
        if apiProtocol == .gemini || provider == .gemini || provider == .custom && (level != nil || geminiBudget != nil) {
            if let level { return ("gemini_level", level.lowercased(), defaultBudget) }
            if let budget = geminiBudget { return ("gemini_budget", budget == 0 ? "none" : "enabled", Int(budget)) }
            return (defaultFormat, "", defaultBudget)
        }
        let claudeEffort = file.string("model.extra_body.output_config.effort")
        let claudeBudget = file.number("model.extra_body.thinking.budget_tokens")
        if apiProtocol == .anthropic || provider == .anthropic || provider == .custom && (claudeEffort != nil || claudeBudget != nil || thinkingType == "adaptive" || thinkingType == "between_tools") {
            if thinkingType == "enabled", let budget = claudeBudget {
                return ("anthropic_budget", "enabled", Int(budget))
            }
            if let effort = claudeEffort { return ("anthropic_effort", effort, defaultBudget) }
            if let budget = claudeBudget { return ("anthropic_budget", thinkingType == "disabled" ? "none" : "enabled", Int(budget)) }
            let format = provider == .custom ? "anthropic_effort" : defaultFormat
            return (format, thinkingType == "disabled" || thinkingType == "between_tools" ? "none" : "", defaultBudget)
        }
        if defaultFormat == "thinking" {
            let effort = thinkingType == "disabled" ? "none" : thinkingType ?? ""
            return (defaultFormat, effort, defaultBudget)
        }
        if defaultFormat == "qwen" || defaultFormat == "siliconflow" {
            let enabled = file.bool("model.extra_body.enable_thinking")
            return (defaultFormat, enabled.map { $0 ? "enabled" : "none" } ?? "", defaultBudget)
        }
        if defaultFormat == "deepseek" {
            return (defaultFormat, thinkingType == "disabled" ? "none" : genericEffort, defaultBudget)
        }
        if provider == .custom {
            if let effort = file.string("model.extra_body.reasoning.effort") { return ("reasoning", effort, defaultBudget) }
            if thinkingType != nil { return ("deepseek", thinkingType == "disabled" ? "none" : genericEffort, defaultBudget) }
            if !genericEffort.isEmpty { return ("openai", genericEffort, defaultBudget) }
            return ("", "", defaultBudget)
        }
        return (defaultFormat, genericEffort, defaultBudget)
    }

    private static func clearReasoningFamily(_ format: String, in file: inout ConfigFile) {
        let fields: [String]
        switch format {
        case "openai": fields = ["reasoning_effort"]
        case "deepseek": fields = ["reasoning_effort", "thinking.type"]
        case "reasoning": fields = ["reasoning.effort"]
        case "thinking": fields = ["thinking.type"]
        case "qwen", "siliconflow": fields = ["enable_thinking", "thinking_budget"]
        case "anthropic_effort", "anthropic_budget":
            fields = ["output_config.effort", "thinking.type", "thinking.budget_tokens"]
        case "gemini_level", "gemini_budget":
            fields = ["generationConfig.thinkingConfig.thinkingLevel", "generationConfig.thinkingConfig.thinkingBudget"]
        default: fields = []
        }
        for field in fields { file.set("model.extra_body." + field, nil) }
        pruneEmptyReasoningObjects(in: &file)
    }

    private static func pruneEmptyReasoningObjects(in file: inout ConfigFile) {
        for path in ["model.extra_body.thinking", "model.extra_body.reasoning", "model.extra_body.output_config",
                     "model.extra_body.generationConfig.thinkingConfig", "model.extra_body.generationConfig",
                     "model.extra_body.chat_template_kwargs", "model.extra_body"] {
            if (file.value(path) as? [String: Any])?.isEmpty == true { file.set(path, nil) }
        }
    }

    /// Saves the speed choice alone and restarts the engine with it. The menu
    /// bar panel calls this on settings read fresh from the file, so the rest
    /// of the file stays exactly as saved.
    func saveSpeed(controller: Controller) async -> Bool {
        do {
            try writeSpeedOnly(to: AppConfig.configPath)
        } catch {
            chatgptMessage = L10n.tr("保存失败：\(error.localizedDescription)", "Could not save: \(error.localizedDescription)")
            return false
        }
        controller.apply(AppConfig.load().0)
        return await controller.restartEngine()
    }

    func writeSpeedOnly(to path: String) throws {
        var file = try ConfigFile.load(from: path)
        writeSpeed(into: &file)
        try file.write(to: path)
    }

    /// Takes a speed choice saved elsewhere when it is for the same model, so
    /// an open settings window doesn't save the old one back over it.
    func adoptSpeed(from other: ModelSettings) {
        guard provider == other.provider, apiProtocol == other.apiProtocol, baseURL == other.baseURL, model == other.model else { return }
        reasoningFormat = other.reasoningFormat
        reasoningEffort = other.reasoningEffort
        thinkingBudget = other.thinkingBudget
        fastMode = other.fastMode
    }

    /// The model as one line: `OpenAI · GPT-6.1-Sol`.
    var summary: String {
        let name = provider == .local ? localModel?.name ?? model
            : chatgptModels.first { $0.slug == model }?.displayName ?? model
        let card = ModelProvider.cards.first { $0.id == provider.cardID }?.name ?? provider.name
        return name.isEmpty ? card : "\(card) · \(name)"
    }

    /// Moves a typed key into the keychain and clears it from memory.
    func storeKey() {
        guard !apiKey.isEmpty else { return }
        if Keychain.save(apiKey, account: currentKeyAccount) {
            hasStoredKey = true
            apiKey = ""
        }
    }

    func forgetKey() {
        if Keychain.save("", account: currentKeyAccount) { hasStoredKey = false }
    }

    // MARK: - ChatGPT sign-in

    func refreshChatGPT(controller: Controller) async {
        guard let r = await controller.engineRequest(["op": "chatgpt_status"], timeout: 5) else {
            chatgptMessage = L10n.tr("连不上引擎", "Cannot connect to the engine")
            return
        }
        guard (r["ok"] as? Bool) == true, let raw = r["chatgpt"] as? [String: Any] else {
            chatgptMessage = r["error"] as? String
            return
        }
        let status = ChatGPTStatus(raw)
        chatgpt = status
        if let error = status.loginError { chatgptMessage = error }
        if status.signedIn && chatgptModels.isEmpty { await loadChatGPTModels(controller: controller) }
    }

    func loadChatGPTModels(controller: Controller) async {
        guard let r = await controller.engineRequest(["op": "chatgpt_models"], timeout: 20) else { return }
        guard (r["ok"] as? Bool) == true else {
            chatgptMessage = r["error"] as? String
            return
        }
        chatgptModels = ((r["models"] as? [[String: Any]]) ?? []).compactMap(ChatGPTModel.init)
        if provider.usesSignIn, !chatgptModels.contains(where: { $0.slug == model }) {
            model = preferredChatGPTModel
        }
    }

    /// Starts the browser sign-in and waits for the engine's loopback
    /// callback to finish it.
    func signInWithChatGPT(controller: Controller) async {
        chatgptMessage = nil
        guard let r = await controller.engineRequest(["op": "chatgpt_login"], timeout: 10),
              (r["ok"] as? Bool) == true, let link = r["auth_url"] as? String, let url = URL(string: link) else {
            chatgptMessage = L10n.tr("没能开始登录，检查引擎是否在运行", "Could not start sign-in. Check that the engine is running.")
            return
        }
        NSWorkspace.shared.open(url)
        chatgpt = ChatGPTStatus(signedIn: false, email: nil, planUsage: false, loginPending: true, loginError: nil)
        for _ in 0..<300 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await refreshChatGPT(controller: controller)
            if chatgpt?.loginPending != true { break }
        }
        if chatgpt?.signedIn == true && !UserDefaults.standard.bool(forKey: Self.planWelcomeKey) {
            showPlanWelcome = true
        }
    }

    func dismissPlanWelcome() {
        UserDefaults.standard.set(true, forKey: Self.planWelcomeKey)
        showPlanWelcome = false
    }

    func signOutOfChatGPT(controller: Controller) async {
        let r = await controller.engineRequest(["op": "chatgpt_logout"], timeout: 30)
        chatgptMessage = r?["note"] as? String
        chatgptModels = []
        await refreshChatGPT(controller: controller)
    }

    /// The engine owns the model request deadline. The IPC wait must leave
    /// enough time for that deadline's error response to arrive at the UI.
    var connectionTestTimeout: TimeInterval {
        if provider == .local { return 180 }
        let effectiveTimeoutMS = timeoutMS > 0 ? timeoutMS : 20000
        return TimeInterval(effectiveTimeoutMS) / 1000 + 5
    }

    /// Writes the config, restarts the engine with it and sends one request.
    func saveAndTest(controller: Controller) async {
        if let problem = validationError {
            testState = .failed(problem)
            return
        }
        let testTimeout = connectionTestTimeout
        testState = .testing
        do {
            var file = try ConfigFile.load(from: AppConfig.configPath)
            write(into: &file)
            try file.write(to: AppConfig.configPath)
        } catch {
            testState = .failed(L10n.tr("保存配置失败：\(error.localizedDescription)", "Could not save configuration: \(error.localizedDescription)"))
            return
        }
        storeKey()
        savedLocalModelID = provider == .local ? localModel?.id : nil
        controller.apply(AppConfig.load().0)
        guard await controller.restartEngine() else {
            testState = .failed(controller.engineRestartProblem())
            return
        }
        // A local model's first start compiles its GPU code and loads
        // gigabytes from disk; give it time.
        let result = await controller.testModel(timeout: testTimeout)
        testState = result.ok ? .passed(result.message) : .failed(result.message)
    }
}

/// The engine's ChatGPT sign-in state.
struct ChatGPTStatus: Equatable {
    let signedIn: Bool
    let email: String?
    let planUsage: Bool
    let loginPending: Bool
    let loginError: String?

    init(signedIn: Bool, email: String?, planUsage: Bool, loginPending: Bool, loginError: String?) {
        self.signedIn = signedIn
        self.email = email
        self.planUsage = planUsage
        self.loginPending = loginPending
        self.loginError = loginError
    }

    init(_ d: [String: Any]) {
        signedIn = (d["signed_in"] as? Bool) ?? false
        email = d["email"] as? String
        planUsage = (d["plan_usage"] as? Bool) ?? false
        loginPending = (d["login_pending"] as? Bool) ?? false
        loginError = d["login_error"] as? String
    }
}

struct ChatGPTModel: Identifiable, Hashable {
    struct Level: Hashable {
        let effort: String
        let description: String
    }

    struct Tier: Hashable {
        let id: String
        let name: String
        let description: String
    }

    let slug: String
    let displayName: String
    var reasoningLevels: [Level] = []
    var defaultReasoning: String?
    var speedTiers: [Tier] = []
    var id: String { slug }

    init(slug: String, displayName: String, reasoningLevels: [Level] = [], defaultReasoning: String? = nil,
         speedTiers: [Tier] = []) {
        self.slug = slug
        self.displayName = displayName
        self.reasoningLevels = reasoningLevels
        self.defaultReasoning = defaultReasoning
        self.speedTiers = speedTiers
    }

    init?(_ d: [String: Any]) {
        guard let slug = d["slug"] as? String, !slug.isEmpty else { return nil }
        self.slug = slug
        displayName = (d["display_name"] as? String) ?? slug
        reasoningLevels = ((d["reasoning_levels"] as? [[String: Any]]) ?? []).compactMap {
            guard let effort = $0["effort"] as? String else { return nil }
            return Level(effort: effort, description: ($0["description"] as? String) ?? "")
        }
        defaultReasoning = d["default_reasoning"] as? String
        speedTiers = ((d["speed_tiers"] as? [[String: Any]]) ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return Tier(id: id, name: ($0["name"] as? String) ?? id, description: ($0["description"] as? String) ?? "")
        }
    }
}

/// The speed choices one provider and model offer.
struct SpeedOptions {
    struct Level: Hashable {
        let effort: String
        let label: String
        let detail: String
    }

    struct FastTier: Hashable {
        let id: String
        let detail: String
    }

    let levels: [Level]
    let fastTier: FastTier?
    /// The level to fall back to when the current one isn't offered.
    var preferred: String? = nil

    var isEmpty: Bool { levels.isEmpty && fastTier == nil }

    /// Reasoning efforts worth offering for a chat reply, fastest first.
    static let replyEfforts = ["minimal", "low", "medium", "high"]

    static func label(for effort: String) -> String {
        switch effort {
        case "": return L10n.tr("默认", "Default")
        case "enabled", "adaptive": return L10n.tr("开启思考", "Thinking on")
        case "none": return L10n.tr("关闭", "Off")
        case "minimal": return L10n.tr("最快", "Fastest")
        case "low": return L10n.tr("低", "Low")
        case "medium": return L10n.tr("中", "Medium")
        case "high": return L10n.tr("高", "High")
        case "xhigh": return L10n.tr("超高", "Extra high")
        case "max": return L10n.tr("最高", "Max")
        default: return effort
        }
    }

    static func detail(for effort: String) -> String {
        switch effort {
        case "": return L10n.tr("使用模型自己的默认推理设置", "Uses the model’s default reasoning settings.")
        case "enabled", "adaptive": return L10n.tr("启用模型的思考模式；支持预算时按指定 token 预算思考", "Enables model thinking; uses the configured token budget when supported.")
        case "none", "minimal": return L10n.tr("最快：几乎不做推理", "Fastest: minimal reasoning.")
        case "low": return L10n.tr("回复快，推理较轻，适合日常聊天", "Fast, light reasoning for everyday chats.")
        case "medium": return L10n.tr("速度和推理深度均衡", "Balances speed and reasoning depth.")
        case "high": return L10n.tr("推理更深，适合复杂问题，会慢一些", "Deeper reasoning for complex questions; takes longer.")
        case "xhigh", "max": return L10n.tr("推理最深，明显更慢", "Deepest reasoning; significantly slower.")
        default: return ""
        }
    }

    /// Reads tier descriptions such as "2x speed, increased usage".
    static func tierDetail(_ description: String) -> String {
        var parts: [String] = []
        if let range = description.range(of: #"[0-9.]+x speed"#, options: .regularExpression) {
            let factor = description[range].replacingOccurrences(of: "x speed", with: "")
            parts.append(L10n.tr("约 \(factor) 倍速度", "About \(factor)× faster"))
        } else {
            parts.append(L10n.tr("更快出结果", "Faster results"))
        }
        if description.localizedCaseInsensitiveContains("usage") {
            parts.append(L10n.tr("会更快消耗套餐额度", "uses your plan allowance faster"))
        }
        return parts.joined(separator: L10n.tr("，", ", "))
    }
}
