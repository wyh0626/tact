import Foundation

/// Settings the app reads from the "app" section of ~/.tact/config.json.
/// The top-level "socket" key is shared with the engine.
struct AppConfig {
    var platformRegistry = PlatformRegistry.empty
    var hotkey = "double+ctrl"
    var socketPath = "~/.tact/engine.sock"
    var engineCommand: [String] = []
    var insertMethod = InsertMethod.auto
    // Where a plugin's chat shows its header and ghost text, from its
    // manifest's desktop rules (PlatformRegistration.runtimeConfig).
    var headerTopOffset: Double = 28   // points below the window's top edge
    var headerHeight: Double = 64
    var headerLeftPadding: Double = 0  // how far left of the input box the header strip starts
    var ghostFontSize: Double = 13
    var ghostOffsetX: Double = 0
    var ghostOffsetY: Double = 0
    var requestTimeout: Double = 25
    var debugSaveHeader = false
    /// Suggestions in WeChat, read off the screen.
    var wechat = false
    /// Environment variable the engine reads the model key from; the app
    /// fills it from the keychain when it starts the engine.
    var apiKeyEnv = ""

    static let defaultAPIKeyEnv = "TACT_API_KEY"
    static let directory = NSString(string: "~/.tact").expandingTildeInPath

    /// The configured engine command, or the engine shipped inside the app
    /// bundle.
    var resolvedEngineCommand: [String] {
        if !engineCommand.isEmpty { return engineCommand }
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "tactd") else { return [] }
        return [bundled.path, "serve"]
    }

    /// Creates ~/.tact on first launch: a style file to edit and a config
    /// with no chat tools, which appear only once they are imported. An
    /// existing config is never touched.
    static func bootstrapIfNeeded(configPath destination: String = AppConfig.configPath,
                                  resources: URL? = Bundle.main.resourceURL,
                                  stateDirectory: String = directory,
                                  log: (String) -> Void = Log.info) {
        guard !FileManager.default.fileExists(atPath: destination), let resources else { return }
        let stylePath = (stateDirectory as NSString).appendingPathComponent("style.md")
        let english = L10n.language == .english
        let localizedTemplate = resources.appendingPathComponent(english ? "style.example.en.md" : "style.example.md")
        // Older resource directories and developer fixtures may only have
        // the original template; keep those working too.
        let hasLocalizedTemplate = FileManager.default.fileExists(atPath: localizedTemplate.path)
        let template = hasLocalizedTemplate ? localizedTemplate : resources.appendingPathComponent("style.example.md")
        let isEnglishTemplate = english && hasLocalizedTemplate
        if !FileManager.default.fileExists(atPath: stylePath) {
            try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? FileManager.default.copyItem(at: template, to: URL(fileURLWithPath: stylePath))
        }
        // A reset configuration can coexist with a user's older style file
        // in another language. Select a section that actually exists in it.
        let preferredSection = isEnglishTemplate ? "Work chats" : "工作聊天"
        let style = (try? String(contentsOfFile: stylePath, encoding: .utf8)) ?? ""
        let sections = style.components(separatedBy: .newlines).compactMap { line -> String? in
            let heading = line.trimmingCharacters(in: .whitespaces)
            guard heading.hasPrefix("## ") else { return nil }
            let name = String(heading.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        let defaultSection = sections.contains(preferredSection) ? preferredSection : sections.first ?? preferredSection
        var file = ConfigFile.initial(styleFile: stylePath,
                                      feedbackFile: (stateDirectory as NSString).appendingPathComponent("feedback.jsonl"),
                                      defaultStyleSection: defaultSection)
        file.set("platforms", [[String: Any]]())
        do {
            try file.write(to: destination)
            log("已创建配置：\(destination)")
        } catch {
            log("⚠️ 创建配置失败：\(error.localizedDescription)")
        }
    }

    static var configPath: String {
        if let p = ProcessInfo.processInfo.environment["TACT_CONFIG"], !p.isEmpty {
            return expand(p)
        }
        return (directory as NSString).appendingPathComponent("config.json")
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    /// Returns the config plus a human-readable problem when the file is
    /// missing or broken (defaults are used in that case).
    static func load() -> (AppConfig, String?) {
        var cfg = AppConfig()
        guard let data = FileManager.default.contents(atPath: configPath) else {
            cfg.socketPath = expand(cfg.socketPath)
            return (cfg, L10n.tr("没找到配置文件 \(configPath)，先运行 scripts/setup.sh",
                                 "Configuration file not found at \(configPath). Run scripts/setup.sh first."))
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            cfg.socketPath = expand(cfg.socketPath)
            return (cfg, L10n.tr("配置文件不是合法的 JSON：\(configPath)", "Invalid JSON in configuration file: \(configPath)"))
        }
        if let v = root["socket"] as? String { cfg.socketPath = v }
        if let v = (root["model"] as? [String: Any])?["api_key_env"] as? String { cfg.apiKeyEnv = v }
        let app = root["app"] as? [String: Any] ?? [:]
        if let v = app["hotkey"] as? String { cfg.hotkey = v }
        if let v = app["engine_command"] as? [String] { cfg.engineCommand = v.map(expand) }
        var problem: String?
        if let v = app["insert_method"] as? String {
            if let method = InsertMethod(rawValue: v) {
                cfg.insertMethod = method
            } else {
                problem = L10n.tr("app.insert_method 只能是 auto、paste 或 ax，现在是 \(v)，先按 auto 处理",
                                  "app.insert_method must be auto, paste or ax; got \(v). Using auto for now.")
            }
        }
        if let v = app["request_timeout_seconds"] as? NSNumber { cfg.requestTimeout = v.doubleValue }
        if let v = app["debug_save_header"] as? Bool { cfg.debugSaveHeader = v }
        if let v = app["wechat"] as? Bool { cfg.wechat = v }
        cfg.socketPath = expand(cfg.socketPath)
        cfg.platformRegistry = PlatformRegistry(file: ConfigFile(root: root))
        return (cfg, problem)
    }
}
