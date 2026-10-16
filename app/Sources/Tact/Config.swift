import CryptoKit
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
    /// Built-in chat apps switched on: read off the screen or through
    /// accessibility, without a plugin.
    var builtIn: Set<BuiltInApp> = []
    /// Environment variable the engine reads the model key from; the app
    /// fills it from the keychain when it starts the engine.
    var apiKeyEnv = ""
    /// Older configurations keep their original keychain entry. New
    /// connections use an account scoped to their provider and origin.
    var modelKeyAccount = Keychain.modelKey

    static let defaultAPIKeyEnv = "TACT_API_KEY"
    static let directory = NSString(string: "~/.tact").expandingTildeInPath

    /// The configured engine command, or the engine shipped inside the app
    /// bundle.
    var resolvedEngineCommand: [String] {
        if !engineCommand.isEmpty { return engineCommand }
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "tactd") else { return [] }
        return [bundled.path, "serve"]
    }

    /// A scoped connection receives only its own saved key. Legacy setups
    /// can still supply their key through the app's launch environment.
    func engineEnvironment(inheriting inherited: [String: String], modelKey: String?) -> [String: String] {
        var environment = inherited
        let keyEnv = apiKeyEnv.isEmpty ? Self.defaultAPIKeyEnv : apiKeyEnv
        if let modelKey, !modelKey.isEmpty {
            environment[keyEnv] = modelKey
        } else if modelKeyAccount != Keychain.modelKey {
            environment.removeValue(forKey: keyEnv)
        }
        return environment
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

    /// SHA-256 of each style template an earlier version installed, and the
    /// template that replaces it. When a template changes, add the hash of
    /// the version being replaced here.
    static let shippedStyles: [String: String] = [
        "3aecb024d712dbfeb57ccea9458a573a54438e9ae6c50cf7ffb18e8212af4e33": "style.example.md",
        "7e11835a182c74bc887775a6120ab3af10ed55baa02d32251c839d4c5e2dc3af": "style.example.en.md",
    ]

    /// A style file nobody edited since an earlier version installed it
    /// takes the current template in the same language, so better defaults
    /// reach people who never changed theirs. An edited file is never touched.
    static func refreshUntouchedStyle(at path: String = (directory as NSString).appendingPathComponent("style.md"),
                                      resources: URL? = Bundle.main.resourceURL,
                                      shipped: [String: String] = shippedStyles,
                                      log: (String) -> Void = Log.info) {
        guard let resources, let current = FileManager.default.contents(atPath: path) else { return }
        let digest = SHA256.hash(data: current).map { String(format: "%02x", $0) }.joined()
        guard let name = shipped[digest],
              let template = FileManager.default.contents(atPath: resources.appendingPathComponent(name).path),
              template != current else { return }
        do {
            try template.write(to: URL(fileURLWithPath: path), options: .atomic)
            log("表达偏好还是默认内容，已换成新版默认模板")
        } catch {
            log("⚠️ 更新默认表达偏好失败：\(error.localizedDescription)")
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
    static func load(from path: String = configPath) -> (AppConfig, String?) {
        var cfg = AppConfig()
        guard let data = FileManager.default.contents(atPath: path) else {
            cfg.socketPath = expand(cfg.socketPath)
            return (cfg, L10n.tr("没找到配置文件 \(path)，先运行 scripts/setup.sh",
                                 "Configuration file not found at \(path). Run scripts/setup.sh first."))
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            cfg.socketPath = expand(cfg.socketPath)
            return (cfg, L10n.tr("配置文件不是合法的 JSON：\(path)", "Invalid JSON in configuration file: \(path)"))
        }
        if let v = root["socket"] as? String { cfg.socketPath = v }
        if let v = (root["model"] as? [String: Any])?["api_key_env"] as? String { cfg.apiKeyEnv = v }
        if let v = (root["model"] as? [String: Any])?["api_key_account"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cfg.modelKeyAccount = v }
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
        cfg.builtIn = Set(BuiltInApp.allCases.filter { app[$0.rawValue] as? Bool == true })
        cfg.socketPath = expand(cfg.socketPath)
        cfg.platformRegistry = PlatformRegistry(file: ConfigFile(root: root))
        return (cfg, problem)
    }
}
