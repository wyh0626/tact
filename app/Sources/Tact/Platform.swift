import Foundation

/// The on-disk contract shared by the desktop host and the engine.
struct PlatformManifest: Codable {
    let protocolVersion: Int
    let id: String
    let name: String
    let version: String
    let transport: String
    let entrypoint: [String]
    let capabilities: [String: Bool]
    let desktop: PlatformDesktop
    let limits: Limits?
    var setup: PluginSetup? = nil

    struct Limits: Codable {
        let timeoutMS: Int
        let chatsCacheSeconds: Int
        enum CodingKeys: String, CodingKey { case timeoutMS = "timeout_ms", chatsCacheSeconds = "chats_cache_seconds" }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            timeoutMS = try values.decodeIfPresent(Int.self, forKey: .timeoutMS) ?? 15000
            chatsCacheSeconds = try values.decodeIfPresent(Int.self, forKey: .chatsCacheSeconds) ?? 300
        }
    }
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", id, name, version, transport, entrypoint, capabilities, desktop, limits, setup
    }

    static func load(at path: String) throws -> PlatformManifest {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 256 * 1024 else { throw PlatformError.invalid("插件清单过大") }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        guard protocolVersion == 1, transport == "command-v1" else {
            throw PlatformError.invalid("不支持这个插件协议版本或传输方式")
        }
        guard Self.validID(id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !entrypoint.isEmpty,
              entrypoint.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !entrypoint.contains(where: { $0.contains("\0") }) else {
            throw PlatformError.invalid("插件身份、版本或启动命令不完整")
        }
        guard capabilities["conversations.list"] == true, capabilities["messages.read"] == true else {
            throw PlatformError.invalid("此版本要求插件实现会话列表和消息读取")
        }
        guard capabilities["events.subscribe"] != true else { throw PlatformError.invalid("command-v1 暂不支持实时事件订阅") }
        if let limits, limits.timeoutMS <= 0 || limits.chatsCacheSeconds < 0 { throw PlatformError.invalid("插件超时和缓存参数不正确") }
        try desktop.validate()
    }

    static func validID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
    }
}

struct PlatformDesktop: Codable, Equatable {
    var strategy: String
    var bundleIDs: [String]
    var header: Header
    var overlay: OverlayStyle
    var sendShortcut: String

    struct Header: Codable, Equatable {
        var topOffset: Double; var height: Double; var leftPadding: Double
        enum CodingKeys: String, CodingKey { case topOffset = "top_offset", height, leftPadding = "left_padding" }
    }
    struct OverlayStyle: Codable, Equatable {
        var fontSize: Double; var offsetX: Double; var offsetY: Double
        enum CodingKeys: String, CodingKey { case fontSize = "font_size", offsetX = "offset_x", offsetY = "offset_y" }
    }
    enum CodingKeys: String, CodingKey {
        case strategy, bundleIDs = "bundle_ids", header, overlay, sendShortcut = "send_shortcut"
    }

    /// The input box through accessibility, the chat by OCR of its header.
    static let accessibilityStrategy = "ax-ocr-v1"
    /// Everything read off the screen, for apps that hide their input box
    /// from accessibility. Tact needs reading rules for the app.
    static let screenStrategy = "screen-ocr-v1"
    static let screenReadable: Set<String> = [TelegramScreen.bundleID]

    func validate() throws {
        if strategy == Self.screenStrategy, !bundleIDs.allSatisfy(Self.screenReadable.contains) {
            throw PlatformError.invalid("Tact 还不会读这个应用的界面，不能用截图方式接入")
        }
        guard [Self.accessibilityStrategy, Self.screenStrategy].contains(strategy), !bundleIDs.isEmpty,
              bundleIDs.allSatisfy({ !$0.isEmpty && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }),
              header.topOffset.isFinite, header.topOffset >= 0,
              header.height.isFinite, header.height > 0, header.height <= 500,
              header.leftPadding.isFinite, overlay.fontSize.isFinite, overlay.fontSize > 0,
              overlay.offsetX.isFinite, overlay.offsetY.isFinite,
              ["return", "command+return", "control+return"].contains(sendShortcut) else {
            throw PlatformError.invalid("不支持或不完整的桌面适配规则")
        }
    }

    static let defaultProfile = PlatformDesktop(strategy: accessibilityStrategy, bundleIDs: [],
                                        header: .init(topOffset: 28, height: 64, leftPadding: 0),
                                        overlay: .init(fontSize: 13, offsetX: 0, offsetY: 0), sendShortcut: "return")
}

enum PlatformError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct PlatformRegistration: Identifiable {
    let id: String
    var configuration: [String: Any]
    let manifest: PlatformManifest?
    let desktop: PlatformDesktop?
    let error: String?
    var enabled: Bool { configuration["enabled"] as? Bool == true }
    var manifestPath: String { configuration["manifest"] as? String ?? "" }
    var available: Bool { error == nil && manifest != nil && desktop != nil }

    var name: String { manifest?.name ?? id }

    func runtimeConfig(from config: AppConfig) -> AppConfig {
        guard let desktop else { return config }
        var result = config
        result.headerTopOffset = desktop.header.topOffset
        result.headerHeight = desktop.header.height
        result.headerLeftPadding = desktop.header.leftPadding
        result.ghostFontSize = desktop.overlay.fontSize
        result.ghostOffsetX = desktop.overlay.offsetX
        result.ghostOffsetY = desktop.overlay.offsetY
        return result
    }
}

/// Loading a registry never starts plugin code. Ambiguous app matches fail
/// closed so two installations cannot accidentally share a conversation.
struct PlatformRegistry {
    let registrations: [PlatformRegistration]

    static let empty = PlatformRegistry(registrations: [])
    private init(registrations: [PlatformRegistration]) { self.registrations = registrations }

    init(file: ConfigFile, configPath: String = AppConfig.configPath) {
        let raw = file.value("platforms")
        if raw == nil || raw is NSNull {
            registrations = []
            return
        }
        guard let instances = raw as? [[String: Any]] else {
            registrations = [.init(id: "invalid", configuration: [:], manifest: nil, desktop: nil,
                                   error: "platforms 必须是插件实例数组")]
            return
        }
        let counts = Dictionary(grouping: instances.compactMap { $0["id"] as? String }, by: { $0 }).mapValues(\.count)
        let base = URL(fileURLWithPath: configPath).deletingLastPathComponent()
        registrations = instances.enumerated().map { index, raw in
            let id = raw["id"] as? String ?? "invalid-\(index)"
            do {
                guard PlatformManifest.validID(id), counts[id] == 1,
                      raw["enabled"] is Bool, let path = raw["manifest"] as? String, !path.isEmpty else {
                    throw PlatformError.invalid("插件实例 ID 重复或配置不完整")
                }
                let expanded = AppConfig.expand(path)
                let absolute = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).path
                var configuration = raw
                configuration["manifest"] = absolute
                let manifest = try PlatformManifest.load(at: absolute)
                var desktop = manifest.desktop
                if raw["desktop"] != nil && !(raw["desktop"] is [String: Any]) {
                    throw PlatformError.invalid("桌面覆盖规则必须是对象")
                }
                if let overrides = raw["desktop"] as? [String: Any] {
                    let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(desktop)) as? [String: Any] ?? [:]
                    let merged = Self.merge(original, overrides)
                    desktop = try JSONDecoder().decode(PlatformDesktop.self, from: JSONSerialization.data(withJSONObject: merged))
                    try desktop.validate()
                }
                if let command = raw["command"] {
                    guard let argv = command as? [String], !argv.isEmpty, !argv[0].isEmpty, !argv.contains(where: { $0.contains("\0") }) else {
                        throw PlatformError.invalid("兼容启动命令格式不正确")
                    }
                }
                return .init(id: id, configuration: configuration, manifest: manifest, desktop: desktop, error: nil)
            } catch {
                return .init(id: id, configuration: raw, manifest: nil, desktop: nil,
                             error: error.localizedDescription)
            }
        }
    }

    func match(bundleID: String?) -> PlatformRegistration? {
        guard let bundleID else { return nil }
        let matches = registrations.filter { $0.enabled && $0.available && $0.desktop?.bundleIDs.contains(bundleID) == true }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func merge(_ base: [String: Any], _ changes: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in changes {
            if let nested = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = merge(existing, nested)
            } else { result[key] = value }
        }
        return result
    }
}
