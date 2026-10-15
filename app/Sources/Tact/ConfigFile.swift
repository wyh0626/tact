import Foundation

/// config.json as raw JSON, for the settings window and first launch. Values
/// are addressed by dotted paths ("model.base_url"); keys the window does not
/// know about are kept as they are.
struct ConfigFile {
    var root: [String: Any]

    static func load(from path: String) throws -> ConfigFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return ConfigFile(root: root)
    }

    /// Atomic, owner-only: the file names the adapter command and model.
    func write(to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func value(_ path: String) -> Any? {
        var node: Any? = root
        for key in path.split(separator: ".") {
            node = (node as? [String: Any])?[String(key)]
        }
        return node
    }

    /// Sets the value at `path`, creating sections as needed; nil removes it.
    mutating func set(_ path: String, _ value: Any?) {
        let keys = path.split(separator: ".").map(String.init)
        root = Self.setting(root, keys[...], value)
    }

    private static func setting(_ dict: [String: Any], _ keys: ArraySlice<String>, _ value: Any?) -> [String: Any] {
        var dict = dict
        guard let key = keys.first else { return dict }
        if keys.count == 1 {
            dict[key] = value
        } else {
            dict[key] = setting(dict[key] as? [String: Any] ?? [:], keys.dropFirst(), value)
        }
        return dict
    }

    func string(_ path: String) -> String? { value(path) as? String }
    func bool(_ path: String) -> Bool? { value(path) as? Bool }
    func number(_ path: String) -> Double? { (value(path) as? NSNumber)?.doubleValue }
    func strings(_ path: String) -> [String] { value(path) as? [String] ?? [] }

    /// The engine refuses a model endpoint outside model.allowed_base_urls,
    /// so choosing an endpoint in the settings window also allows its origin.
    mutating func allowModelOrigin(of baseURL: String) {
        guard let origin = Self.origin(of: baseURL) else { return }
        var allowed = strings("model.allowed_base_urls")
        if !allowed.contains(origin) {
            allowed.append(origin)
            set("model.allowed_base_urls", allowed)
        }
    }

    static func origin(of url: String) -> String? {
        guard let comps = URLComponents(string: url.trimmingCharacters(in: .whitespaces)),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else { return nil }
        if let port = comps.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// Written on first launch of the app bundle, when there is no config yet.
    static func initial(styleFile: String, feedbackFile: String, defaultStyleSection: String = "工作聊天") -> ConfigFile {
        ConfigFile(root: [
            "socket": "~/.tact/engine.sock",
            "model": [
                "provider": "deepseek",
                "base_url": ModelProvider.deepseek.baseURL,
                "model": ModelProvider.deepseek.defaultModel,
                "api_key_env": AppConfig.defaultAPIKeyEnv,
                "timeout_ms": 20000,
                "temperature": 0.3,
                "max_tokens": 300,
                "allowed_base_urls": ModelProvider.presets.compactMap { origin(of: $0.baseURL) },
                "extra_body": ["thinking": ["type": "disabled"]],
            ],
            "context": [
                "history_limit": 20,
                "max_message_chars": 500,
                "max_suggestion_chars": 300,
                "history_cache_seconds": 20,
            ],
            "style": [
                "file": styleFile,
                "default_section": defaultStyleSection,
            ],
            "feedback": [
                "file": feedbackFile,
                "log_plaintext": false,
            ],
            "app": [
                "hotkey": "double+ctrl",
                "insert_method": "auto",
            ],
        ])
    }
}

/// How a provider lets the user trade speed against reasoning depth.
enum SpeedControls: Hashable {
    /// No shared speed controls. Native and custom APIs use model capabilities.
    case none
    /// DeepSeek: thinking off, or on at low / high / max effort.
    case deepseek
    /// OpenAI with an API key: reasoning_effort and the Fast (priority) tier.
    case openai
    /// ChatGPT sign-in: levels and tiers come from each model's metadata.
    case chatgpt
}

/// Whether a provider takes an API key.
enum KeyPolicy: Hashable {
    case required, optional, none
}

/// The request protocol is independent of the service's brand or host.
enum ModelProtocol: String, CaseIterable, Identifiable {
    case openai, responses, anthropic, gemini
    var id: String { rawValue }
    var name: String {
        switch self {
        case .openai: return "OpenAI Chat Completions"
        case .responses: return "OpenAI Responses"
        case .anthropic: return "Anthropic Messages"
        case .gemini: return "Gemini GenerateContent"
        }
    }
    var endpointDetail: String {
        switch self {
        case .openai, .responses: return L10n.tr("API 基址，例如 https://example.com/v1，不含请求路径", "API base URL, e.g. https://example.com/v1, without the request path")
        case .anthropic: return L10n.tr("Anthropic API 基址，不含 /v1/messages", "Anthropic API base URL, without /v1/messages")
        case .gemini: return L10n.tr("Gemini API 基址，不含模型路径", "Gemini API base URL, without the model path")
        }
    }
    static func resolved(_ raw: String?, provider: ModelProvider) -> ModelProtocol {
        raw.flatMap(Self.init(rawValue:)) ?? provider.defaultProtocol
    }
}

/// Model endpoints offered in onboarding and settings.
struct ModelProvider: Identifiable, Hashable {
    let id: String
    var name: String {
        switch id {
        case "chatgpt": return L10n.tr("ChatGPT 账号", "ChatGPT account")
        case "deepseek": return "DeepSeek"
        case "openai": return "OpenAI"
        case "anthropic": return "Claude"
        case "gemini": return "Gemini"
        case "zhipu": return L10n.tr("智谱", "Zhipu")
        case "moonshot": return "Kimi"
        case "qwen": return L10n.tr("通义千问", "Qwen")
        case "doubao": return L10n.tr("豆包", "Doubao")
        case "siliconflow": return L10n.tr("硅基流动", "SiliconFlow")
        case "openrouter": return "OpenRouter"
        case "minimax": return "MiniMax"
        case "local": return L10n.tr("本机", "Local")
        default: return L10n.tr("自定义", "Custom")
        }
    }
    var detail: String {
        switch id {
        case "chatgpt": return L10n.tr("用你的 Plus / Pro 套餐额度，不需要 API Key", "Uses your Plus / Pro plan. No API key needed.")
        case "deepseek": return L10n.tr("云端，便宜、中文好", "Cloud model; affordable, strong in Chinese")
        case "openai": return L10n.tr("ChatGPT 账号或 API Key", "ChatGPT account or API key")
        case "anthropic": return L10n.tr("Anthropic 原生接口，用 API Key", "Anthropic API with an API key")
        case "gemini": return L10n.tr("Google 原生接口，用 API Key", "Google API with an API key")
        case "local": return L10n.tr("下载模型到这台 Mac，聊天内容不出电脑", "Download to this Mac; keep chats on-device")
        case "zhipu": return L10n.tr("智谱 BigModel 标准 API", "BigModel standard API")
        case "moonshot": return L10n.tr("月之暗面 Moonshot API", "Moonshot AI API")
        case "qwen": return L10n.tr("阿里云百炼，北京地域", "Alibaba Cloud Model Studio, Beijing")
        case "doubao": return L10n.tr("火山方舟，北京地域", "Volcengine Ark, Beijing")
        case "siliconflow": return L10n.tr("国内多模型推理服务", "Multi-model inference service")
        case "openrouter": return L10n.tr("统一路由多家模型服务", "Routes requests to multiple model providers")
        case "minimax": return L10n.tr("MiniMax 国内标准 API", "MiniMax China standard API")
        default: return L10n.tr("选择接口协议，连接公司网关或其他模型服务", "Choose a protocol for a gateway or another model service")
        }
    }
    let baseURL: String
    let defaultModel: String
    let key: KeyPolicy
    /// What the provider offers for trading speed against reasoning.
    let speed: SpeedControls
    let symbol: String
    /// Signs in with a ChatGPT account and bills the user's plan; no key.
    var usesSignIn = false

    static let chatgpt = ModelProvider(
        id: "chatgpt",
        // Luna costs less of the plan than the larger models; plenty for a reply.
        baseURL: "https://api.openai.com/v1", defaultModel: "gpt-5.6-luna", key: .none, speed: .chatgpt,
        symbol: "person.crop.circle", usesSignIn: true)
    static let deepseek = ModelProvider(
        id: "deepseek", baseURL: "https://api.deepseek.com/v1",
        defaultModel: "deepseek-flash", key: .required, speed: .deepseek, symbol: "cloud")
    static let openai = ModelProvider(
        id: "openai", baseURL: "https://api.openai.com/v1",
        defaultModel: "", key: .required, speed: .openai, symbol: "sparkles")
    static let anthropic = ModelProvider(
        id: "anthropic", baseURL: "https://api.anthropic.com",
        defaultModel: "", key: .required, speed: .none, symbol: "asterisk")
    static let gemini = ModelProvider(
        id: "gemini", baseURL: "https://generativelanguage.googleapis.com",
        defaultModel: "", key: .required, speed: .none, symbol: "diamond")
    /// A downloaded model run by the llama-server inside the app.
    static let local = ModelProvider(
        id: "local", baseURL: "",
        defaultModel: "", key: .none, speed: .none, symbol: "desktopcomputer")
    static let custom = ModelProvider(
        id: "custom", baseURL: "",
        defaultModel: "", key: .optional, speed: .none, symbol: "slider.horizontal.3")

    static let zhipu = ModelProvider(id: "zhipu", baseURL: "https://open.bigmodel.cn/api/paas/v4", defaultModel: "", key: .required, speed: .none, symbol: "brain")
    static let moonshot = ModelProvider(id: "moonshot", baseURL: "https://api.moonshot.cn/v1", defaultModel: "", key: .required, speed: .none, symbol: "moon")
    static let qwen = ModelProvider(id: "qwen", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", defaultModel: "", key: .required, speed: .none, symbol: "cloud")
    static let doubao = ModelProvider(id: "doubao", baseURL: "https://ark.cn-beijing.volces.com/api/v3", defaultModel: "", key: .required, speed: .none, symbol: "bubble.left")
    static let siliconflow = ModelProvider(id: "siliconflow", baseURL: "https://api.siliconflow.cn/v1", defaultModel: "", key: .required, speed: .none, symbol: "square.stack.3d.up")
    static let openrouter = ModelProvider(id: "openrouter", baseURL: "https://openrouter.ai/api/v1", defaultModel: "", key: .required, speed: .none, symbol: "arrow.triangle.branch")
    static let minimax = ModelProvider(id: "minimax", baseURL: "https://api.minimax.cn/v1", defaultModel: "", key: .required, speed: .none, symbol: "waveform")

    /// Presets use regional standard API endpoints; other regions/plans remain editable.
    static let presets = [openai, deepseek, anthropic, gemini, zhipu, moonshot, qwen, doubao, siliconflow, openrouter, minimax, custom]
    /// The provider cards. ChatGPT sign-in is OpenAI with another way in,
    /// so it shares OpenAI's card and is picked inside it.
    static let cards = [openai, deepseek, anthropic, gemini, zhipu, moonshot, qwen, doubao, siliconflow, openrouter, minimax, local, custom]

    /// The card this provider is shown under.
    var cardID: String { usesSignIn ? ModelProvider.openai.id : id }

    /// A newly selected custom connection records its protocol explicitly.
    var configurationValue: String? { id }

    var defaultProtocol: ModelProtocol {
        switch id {
        case "anthropic": return .anthropic
        case "gemini": return .gemini
        default: return .openai
        }
    }
    /// The account keeps its dedicated OAuth Responses path.
    var apiProtocol: String { usesSignIn ? id : defaultProtocol.rawValue }

    var endpointDetail: String {
        switch id {
        case "anthropic": return L10n.tr("Anthropic API 的基址，不含 /v1/messages", "Anthropic API base URL, without /v1/messages")
        case "gemini": return L10n.tr("Gemini API 的基址，不含模型路径", "Gemini API base URL, without the model path")
        default: return L10n.tr("兼容 OpenAI 的 /v1 地址", "An OpenAI-compatible /v1 URL")
        }
    }

    /// The preset an existing config belongs to. ChatGPT sign-in shares
    /// OpenAI's endpoint and a local model has none, so both are told apart
    /// by model.provider.
    static func matching(provider: String?, baseURL: String) -> ModelProvider {
        if provider == "chatgpt" { return chatgpt }
        if provider == "local" { return local }
        if provider == "deepseek" { return deepseek }
        if provider == "anthropic" { return anthropic }
        if provider == "gemini" { return gemini }
        if provider == "custom" { return custom }
        if let known = [zhipu, moonshot, qwen, doubao, siliconflow, openrouter, minimax].first(where: { $0.id == provider }) { return known }
        let origin = ConfigFile.origin(of: baseURL)
        return [deepseek, openai, zhipu, moonshot, qwen, doubao, siliconflow, openrouter, minimax].first { ConfigFile.origin(of: $0.baseURL) == origin } ?? custom
    }
}
