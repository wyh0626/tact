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
    /// Nothing to set (local models, custom endpoints).
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

/// Model endpoints offered in onboarding and settings. Any OpenAI-compatible
/// endpoint works through "custom".
struct ModelProvider: Identifiable, Hashable {
    let id: String
    var name: String {
        switch id {
        case "chatgpt": return L10n.tr("ChatGPT 账号", "ChatGPT account")
        case "deepseek": return "DeepSeek"
        case "openai": return "OpenAI"
        case "local": return L10n.tr("本机", "Local")
        default: return L10n.tr("自定义", "Custom")
        }
    }
    var detail: String {
        switch id {
        case "chatgpt": return L10n.tr("用你的 Plus / Pro 套餐额度，不需要 API Key", "Uses your Plus / Pro plan. No API key needed.")
        case "deepseek": return L10n.tr("云端，便宜、中文好", "Cloud model; affordable, strong in Chinese")
        case "openai": return L10n.tr("ChatGPT 账号或 API Key", "ChatGPT account or API key")
        case "local": return L10n.tr("下载模型到这台 Mac，聊天内容不出电脑", "Download to this Mac; keep chats on-device")
        default: return L10n.tr("任何兼容 OpenAI 接口的服务，比如 Ollama、公司网关", "Any OpenAI-compatible service, such as Ollama")
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
    /// A downloaded model run by the llama-server inside the app.
    static let local = ModelProvider(
        id: "local", baseURL: "",
        defaultModel: "", key: .none, speed: .none, symbol: "desktopcomputer")
    static let custom = ModelProvider(
        id: "custom", baseURL: "",
        defaultModel: "", key: .optional, speed: .none, symbol: "slider.horizontal.3")

    /// Endpoints a config is matched to by its base URL.
    static let presets = [deepseek, openai, custom]
    /// The provider cards. ChatGPT sign-in is OpenAI with another way in,
    /// so it shares OpenAI's card and is picked inside it.
    static let cards = [openai, deepseek, local, custom]

    /// The card this provider is shown under.
    var cardID: String { usesSignIn ? ModelProvider.openai.id : id }

    /// The preset an existing config belongs to. ChatGPT sign-in shares
    /// OpenAI's endpoint and a local model has none, so both are told apart
    /// by model.provider.
    static func matching(provider: String?, baseURL: String) -> ModelProvider {
        if provider == "chatgpt" { return chatgpt }
        if provider == "local" { return local }
        let origin = ConfigFile.origin(of: baseURL)
        return presets.first { !$0.baseURL.isEmpty && ConfigFile.origin(of: $0.baseURL) == origin } ?? custom
    }
}
