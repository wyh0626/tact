import AppKit

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
    @Published var baseURL: String
    @Published var model: String
    /// A newly typed key; empty keeps the one already in the keychain.
    @Published var apiKey = ""
    @Published private(set) var hasStoredKey: Bool
    /// Reasoning effort to request; "" leaves the model's default, and for
    /// DeepSeek "none" means thinking off.
    @Published var reasoningEffort: String
    /// Ask for the provider's Fast tier.
    @Published var fastMode: Bool
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
        baseURL = base
        model = file.string("model.model") ?? ""
        hasStoredKey = !(Keychain.read(Keychain.modelKey) ?? "").isEmpty
        let thinkingDisabled = (file.value("model.extra_body.thinking.type") as? String) == "disabled"
        let effort = file.string("model.reasoning_effort") ?? ""
        reasoningEffort = matched.speed == .deepseek && (thinkingDisabled || effort.isEmpty) ? "none" : effort
        fastMode = !(file.string("model.service_tier") ?? "").isEmpty
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
        provider = preset
        if !preset.baseURL.isEmpty || preset == .local { baseURL = preset.baseURL }
        if preset == .local {
            model = localModelID
        } else if preset.usesSignIn {
            // Models come from the signed-in account's list.
            if !chatgptModels.contains(where: { $0.slug == model }) { model = preferredChatGPTModel }
        } else if preset != previous {
            // A model name means nothing to another provider.
            model = preset.defaultModel
        }
        reasoningEffort = preset.speed == .deepseek ? "none" : ""
        fastMode = false
        testState = .idle
    }

    // MARK: - Speed

    var speedOptions: SpeedOptions {
        switch provider.speed {
        case .none:
            return SpeedOptions(levels: [], fastTier: nil)
        case .deepseek:
            return SpeedOptions(levels: [
                .init(effort: "none", label: "关闭思考", detail: "最快：直接回答，不做深度思考"),
                .init(effort: "low", label: "低", detail: SpeedOptions.detail(for: "low")),
                .init(effort: "high", label: "高", detail: SpeedOptions.detail(for: "high")),
                .init(effort: "max", label: "最高", detail: SpeedOptions.detail(for: "max")),
            ], fastTier: nil)
        case .openai:
            return SpeedOptions(levels: [
                .init(effort: "", label: "默认", detail: "用模型自己的默认推理程度"),
                .init(effort: "low", label: "低", detail: SpeedOptions.detail(for: "low")),
                .init(effort: "medium", label: "中", detail: SpeedOptions.detail(for: "medium")),
                .init(effort: "high", label: "高", detail: SpeedOptions.detail(for: "high")),
            ], fastTier: .init(id: "priority", detail: "更快出结果，按更高的价格计费"))
        case .chatgpt:
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
                                          detail: effort == selected.defaultReasoning ? "模型默认。" + detail : detail)
            }
            let preferred = useful.contains(selected.defaultReasoning ?? "") ? selected.defaultReasoning
                : useful.contains("low") ? "low" : useful.first
            return SpeedOptions(levels: levels, fastTier: tier, preferred: preferred)
        }
    }

    /// Keeps the choice valid after the model changes: an effort the new
    /// model lacks falls back to its default, no levels means the model's
    /// own default, and Fast goes off without a tier.
    func reconcileSpeed() {
        let options = speedOptions
        if options.levels.isEmpty {
            if provider.speed == .chatgpt { reasoningEffort = "" }
        } else if !options.levels.contains(where: { $0.effort == reasoningEffort }) {
            reasoningEffort = options.preferred ?? options.levels.first?.effort ?? ""
        }
        if options.fastTier == nil { fastMode = false }
    }

    var keyRequired: Bool { provider.key == .required }

    var localModel: LocalModel? { LocalModel.named(localModelID) }

    /// Picks a downloaded model; saving puts it to use.
    func useLocalModel(_ chosen: LocalModel) {
        localModelID = chosen.id
        if provider == .local { model = chosen.id }
        testState = .idle
    }

    var validationError: String? {
        if provider == .local {
            guard let chosen = localModel else { return "选一个本机模型" }
            if !localStore.isReady(chosen) { return "先下载 \(chosen.name)" }
            return nil
        }
        if provider.usesSignIn {
            guard let status = chatgpt, status.signedIn else { return "先用 ChatGPT 账号登录" }
            if !status.planUsage { return "登录时没有授权使用 ChatGPT 套餐，退出后重新登录并允许" }
            if model.isEmpty { return "选一个模型" }
            return nil
        }
        if ConfigFile.origin(of: baseURL) == nil { return "接口地址要以 http:// 或 https:// 开头" }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "填写模型名" }
        if keyRequired && apiKey.isEmpty && !hasStoredKey { return "填写 API Key" }
        return nil
    }

    func write(into file: inout ConfigFile) {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        file.set("model.provider", provider.usesSignIn ? "chatgpt" : provider == .local ? "local" : nil)
        file.set("model.base_url", base)
        file.set("model.model", model.trimmingCharacters(in: .whitespaces))
        if (file.string("model.api_key_env") ?? "").isEmpty {
            file.set("model.api_key_env", AppConfig.defaultAPIKeyEnv)
        }
        file.allowModelOrigin(of: base)
        writeSpeed(into: &file)
        writeLocal(into: &file)
    }

    /// The local model's file, and its thinking turned off where the model
    /// would otherwise think before every reply.
    private func writeLocal(into file: inout ConfigFile) {
        file.set("model.extra_body.chat_template_kwargs", nil)
        if provider == .local, let chosen = localModel {
            file.set("model.local", ["path": localStore.url(for: chosen).path])
            if chosen.thinks { file.set("model.extra_body.chat_template_kwargs", ["enable_thinking": false]) }
        } else {
            file.set("model.local", nil)
        }
        if (file.value("model.extra_body") as? [String: Any])?.isEmpty == true {
            file.set("model.extra_body", nil)
        }
    }

    private func writeSpeed(into file: inout ConfigFile) {
        let effort = reasoningEffort
        file.set("model.extra_body.thinking", nil)
        file.set("model.reasoning_effort", nil)
        file.set("model.service_tier", nil)
        switch provider.speed {
        case .none:
            break
        case .deepseek:
            if effort == "none" || effort.isEmpty {
                file.set("model.extra_body.thinking", ["type": "disabled"])
            } else {
                file.set("model.reasoning_effort", effort)
            }
        case .openai, .chatgpt:
            if !effort.isEmpty { file.set("model.reasoning_effort", effort) }
            if fastMode, let tier = speedOptions.fastTier { file.set("model.service_tier", tier.id) }
        }
        if (file.value("model.extra_body") as? [String: Any])?.isEmpty == true {
            file.set("model.extra_body", nil)
        }
    }

    /// Saves the speed choice alone and restarts the engine with it. The menu
    /// bar panel calls this on settings read fresh from the file, so the rest
    /// of the file stays exactly as saved.
    func saveSpeed(controller: Controller) async -> Bool {
        do {
            try writeSpeedOnly(to: AppConfig.configPath)
        } catch {
            chatgptMessage = "保存失败：\(error.localizedDescription)"
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
        guard provider == other.provider, model == other.model else { return }
        reasoningEffort = other.reasoningEffort
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
        if Keychain.save(apiKey, account: Keychain.modelKey) {
            hasStoredKey = true
            apiKey = ""
        }
    }

    func forgetKey() {
        if Keychain.save("", account: Keychain.modelKey) { hasStoredKey = false }
    }

    // MARK: - ChatGPT sign-in

    func refreshChatGPT(controller: Controller) async {
        guard let r = await controller.engineRequest(["op": "chatgpt_status"], timeout: 5) else {
            chatgptMessage = "连不上引擎"
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
            chatgptMessage = "没能开始登录，检查引擎是否在运行"
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

    /// Writes the config, restarts the engine with it and sends one request.
    func saveAndTest(controller: Controller) async {
        if let problem = validationError {
            testState = .failed(problem)
            return
        }
        testState = .testing
        do {
            var file = try ConfigFile.load(from: AppConfig.configPath)
            write(into: &file)
            try file.write(to: AppConfig.configPath)
        } catch {
            testState = .failed("保存配置失败：\(error.localizedDescription)")
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
        let result = await controller.testModel(timeout: provider == .local ? 180 : 30)
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
        case "none": return "关闭"
        case "minimal": return "最快"
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "超高"
        case "max": return "最高"
        default: return effort
        }
    }

    static func detail(for effort: String) -> String {
        switch effort {
        case "none", "minimal": return "最快：几乎不做推理"
        case "low": return "回复快，推理较轻，适合日常聊天"
        case "medium": return "速度和推理深度均衡"
        case "high": return "推理更深，适合复杂问题，会慢一些"
        case "xhigh", "max": return "推理最深，明显更慢"
        default: return ""
        }
    }

    /// Reads tier descriptions such as "2x speed, increased usage".
    static func tierDetail(_ description: String) -> String {
        var parts: [String] = []
        if let range = description.range(of: #"[0-9.]+x speed"#, options: .regularExpression) {
            let factor = description[range].replacingOccurrences(of: "x speed", with: "")
            parts.append("约 \(factor) 倍速度")
        } else {
            parts.append("更快出结果")
        }
        if description.localizedCaseInsensitiveContains("usage") {
            parts.append("会更快消耗套餐额度")
        }
        return parts.joined(separator: "，")
    }
}
