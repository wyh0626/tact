import AppKit

struct PlatformEntry: Identifiable {
    let id: String
    let name: String
    let version: String
    let supported: Bool
    let supportsSuggestions: Bool
    let enabled: Bool
    let status: String
    let tone: StatusTone
    /// Whether `status` reports a connection check, finished or running.
    let checked: Bool
    let capabilityLabels: [String]
    let removable: Bool
}

/// A chat platform people ask for that no plugin serves yet.
struct PlannedPlatform: Identifiable {
    let id: String
    let name: String
}

@MainActor
final class PlatformSettings: ObservableObject {
    /// WeChat is built in (see WeChatAssistant) and Telegram has a plugin
    /// (plugins/telegram), so neither is here.
    static let planned = [PlannedPlatform(id: "dingtalk", name: "钉钉"), .init(id: "feishu", name: "飞书"),
                          .init(id: "slack", name: "Slack"), .init(id: "discord", name: "Discord")]

    @Published private(set) var entries: [PlatformEntry] = []
    @Published var selectedID: String?
    @Published var problem: String?
    @Published var busy = false
    /// The plugin whose connection is being checked right now.
    @Published private(set) var checkingID: String?
    @Published var targetBundleID = ""
    @Published var headerTopOffset: Double = 28
    @Published var headerHeight: Double = 64
    @Published private(set) var ocrTestMode: Bool

    private let controller: Controller
    private let configPath: String
    private var registry: PlatformRegistry
    private var checks: [String: (ok: Bool, message: String)] = [:]
    private var verifiedIDs = Set<String>()
    private var pendingRestart: Task<Void, Never>?
    private var pluginDirectory: URL {
        URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("plugins", isDirectory: true)
    }
    var selected: PlatformEntry? { entries.first { $0.id == selectedID } }
    var selectedSetup: PluginSetup? { selectedManifest?.setup }
    var selectedPluginDirectory: String? {
        registry.registrations.first { $0.id == selectedID }.map {
            URL(fileURLWithPath: $0.manifestPath).deletingLastPathComponent().path
        }
    }
    var selectedConnectionVerified: Bool { selectedID.map { verifiedIDs.contains($0) } ?? false }
    private var selectedManifest: PlatformManifest? { registry.registrations.first { $0.id == selectedID }?.manifest }

    /// What a connection check will run, with the plugin folder left out so
    /// the line stays readable: `/usr/bin/python3 adapter.py`.
    var selectedCommand: String? {
        guard let entrypoint = selectedManifest?.entrypoint else { return nil }
        return entrypoint.map { $0.replacingOccurrences(of: "${plugin_dir}/", with: "") }.joined(separator: " ")
    }

    var selectedIdentity: String? {
        guard let manifest = selectedManifest else { return nil }
        return "\(manifest.id) · v\(manifest.version)"
    }

    init(controller: Controller, file: ConfigFile, configPath: String = AppConfig.configPath) {
        self.controller = controller
        self.configPath = configPath
        ocrTestMode = controller.ocrTestMode
        registry = PlatformRegistry(file: file, configPath: configPath)
        rebuild()
        if let first = entries.first { select(first.id) }
    }

    func select(_ id: String) {
        guard let registration = registry.registrations.first(where: { $0.id == id }) else { return }
        selectedID = id
        let desktop = registration.desktop ?? .defaultProfile
        targetBundleID = desktop.bundleIDs.joined(separator: ", ")
        headerTopOffset = desktop.header.topOffset
        headerHeight = desktop.header.height
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: String) -> Bool {
        guard !busy, let entry = entries.first(where: { $0.id == id }), entry.supported || !enabled else { return false }
        if enabled && !verifiedIDs.contains(id) { problem = "请先检测连接，成功后再启用这个聊天工具"; return false }
        let previousCheck = checks[id]
        let wasVerified = verifiedIDs.contains(id)
        if save({ instances in
            if let index = instances.firstIndex(where: { $0["id"] as? String == id }) { instances[index]["enabled"] = enabled }
        }) {
            checks[id] = previousCheck
            if wasVerified { verifiedIDs.insert(id) }
            rebuild()
            return true
        }
        return false
    }

    /// Returns once the saved configuration has taken effect.
    func setEnabledAndWait(_ enabled: Bool, id: String) async -> Bool {
        if !busy, entries.first(where: { $0.id == id })?.enabled == enabled,
           !enabled || verifiedIDs.contains(id) { return problem == nil }
        guard setEnabled(enabled, id: id) else { return false }
        await pendingRestart?.value
        return problem == nil && entries.first(where: { $0.id == id })?.enabled == enabled
    }

    /// Turning a plugin on is one step for the user: check the connection
    /// first if it hasn't passed yet, and enable it only when it does.
    @discardableResult
    func checkAndEnable(id: String) async -> Bool {
        guard !busy, entries.first(where: { $0.id == id })?.supported == true else { return false }
        select(id)
        if !verifiedIDs.contains(id) { await testSelected() }
        guard verifiedIDs.contains(id) else { return false }
        return await setEnabledAndWait(true, id: id)
    }

    func saveSelectedDesktop() {
        guard !busy, let id = selectedID, selected?.supported == true else { return }
        let bundles = targetBundleID.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var desktop = registry.registrations.first(where: { $0.id == id })?.desktop ?? .defaultProfile
        desktop.bundleIDs = bundles
        desktop.header.topOffset = headerTopOffset
        desktop.header.height = headerHeight
        do { try desktop.validate() } catch { problem = error.localizedDescription; return }
        save { instances in
            if let index = instances.firstIndex(where: { $0["id"] as? String == id }) {
                var existing = instances[index]["desktop"] as? [String: Any] ?? [:]
                existing["bundle_ids"] = bundles
                var header = existing["header"] as? [String: Any] ?? [:]
                header["top_offset"] = self.headerTopOffset
                header["height"] = self.headerHeight
                existing["header"] = header
                instances[index]["desktop"] = existing
            }
        }
    }

    func setOCRTestMode(_ on: Bool) {
        controller.ocrTestMode = on
        ocrTestMode = on
    }

    func saveNextHeader() {
        controller.saveNextHeader = true
    }

    /// A check is the only settings action that starts plugin code and reads
    /// a conversation list. Import and selection only inspect the manifest.
    /// Its outcome shows on the plugin's own row.
    func testSelected() async {
        guard !busy, let id = selectedID, selected?.supported == true else { return }
        busy = true
        checkingID = id
        rebuild()
        defer { busy = false; checkingID = nil; rebuild() }
        let result = await controller.checkPlatformConnection(id: id)
        checks[id] = (result.ok, result.message)
        if result.ok { verifiedIDs.insert(id); problem = nil } else { verifiedIDs.remove(id) }
    }

    /// Registers a plugin, disabled, from a folder or a .zip of one. Returns
    /// whether it was added; on failure `problem` says why.
    @discardableResult
    func importPlugin(from source: URL) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let destination = pluginDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            // Unpacking and copying can take time; keep tab switching responsive.
            try await Task.detached(priority: .utility) {
                let package = try PluginPackage.open(source)
                defer { package.close() }
                _ = try PlatformManifest.load(at: package.root.appendingPathComponent("manifest.json").path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try FileManager.default.copyItem(at: package.root, to: destination)
                _ = try PlatformManifest.load(at: destination.appendingPathComponent("manifest.json").path)
            }.value
            let id = "custom-" + UUID().uuidString.lowercased()
            let previousSelection = selectedID
            selectedID = id
            guard save({ $0.append(["id": id, "manifest": destination.appendingPathComponent("manifest.json").path, "enabled": false, "origin": "imported"]) }, restart: false) else {
                selectedID = previousSelection
                try? FileManager.default.removeItem(at: destination)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            problem = "导入失败：\(error.localizedDescription)"
            return false
        }
    }

    func removeSelected() {
        guard !busy, let entry = selected, entry.removable else { return }
        // Unregister only. Keeping its files makes an accidental removal recoverable.
        _ = save { $0.removeAll { $0["id"] as? String == entry.id } }
    }

    func openPluginFolder() {
        guard let path = registry.registrations.first(where: { $0.id == selectedID })?.manifestPath, !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path).deletingLastPathComponent())
    }

    @discardableResult
    private func save(_ change: (inout [[String: Any]]) -> Void, restart: Bool = true) -> Bool {
        do {
            var file = try ConfigFile.load(from: configPath)
            let existing = PlatformRegistry(file: file, configPath: configPath)
            var instances = existing.registrations.map(\.configuration)
            change(&instances)
            file.set("platforms", instances)
            let candidate = PlatformRegistry(file: file, configPath: configPath)
            // Invalid entries can be disabled or removed, but cannot be enabled.
            if let invalid = candidate.registrations.first(where: { candidate in
                candidate.enabled && !candidate.available && !existing.registrations.contains(where: { $0.id == candidate.id && $0.enabled && !$0.available })
            }) {
                throw PlatformError.invalid(invalid.error ?? "插件不可用")
            }
            let active = candidate.registrations.filter { $0.enabled && $0.available }
            var owners = Set<String>()
            for platform in active {
                for bundle in Set(platform.desktop?.bundleIDs ?? []) {
                    guard owners.insert(bundle).inserted else { throw PlatformError.invalid("同一个应用只能启用一个插件，请先停用重复的平台") }
                }
            }
            try file.write(to: configPath)
            registry = candidate
            checks.removeAll()
            verifiedIDs.removeAll()
            problem = nil
            rebuild()
            if let id = selectedID ?? entries.first?.id { select(id) }
            if configPath == AppConfig.configPath { controller.apply(AppConfig.load().0) }
        } catch {
            problem = "保存失败：\(error.localizedDescription)"
            return false
        }
        if restart {
            busy = true
            pendingRestart = Task {
                if !(await controller.restartEngine()) { problem = "配置已保存，但" + controller.engineRestartProblem() }
                busy = false
                pendingRestart = nil
            }
        }
        return true
    }

    private func rebuild() {
        let capabilityNames = [("conversations.list", "会话列表"), ("messages.read", "消息读取"),
                               ("composer.read", "输入框读取"), ("composer.apply", "填入草稿"),
                               ("overlay.inline", "行内建议"), ("events.subscribe", "实时事件")]
        entries = registry.registrations.map { registration in
            let capabilities = registration.manifest?.capabilities ?? [:]
            let (status, tone) = Self.status(of: registration, check: checks[registration.id],
                                             checking: checkingID == registration.id)
            return PlatformEntry(id: registration.id, name: registration.name,
                                 version: registration.manifest?.version ?? "",
                                 supported: registration.available,
                                 supportsSuggestions: capabilities["composer.read"] == true && capabilities["composer.apply"] == true,
                                 enabled: registration.enabled, status: status, tone: tone,
                                 checked: checks[registration.id] != nil || checkingID == registration.id,
                                 capabilityLabels: capabilityNames.filter { capabilities[$0.0] == true }.map(\.1),
                                 removable: true)
        }
        if !entries.contains(where: { $0.id == selectedID }) { selectedID = entries.first?.id }
    }

    private static func status(of registration: PlatformRegistration, check: (ok: Bool, message: String)?,
                               checking: Bool) -> (String, StatusTone) {
        if let error = registration.error { return (error, .warn) }
        if checking { return ("正在检测连接…", .neutral) }
        if let check, !check.ok { return (check.message, .warn) }
        if registration.enabled { return (check.map { "已启用 · \($0.message)" } ?? "已启用", .ok) }
        if let check { return ("\(check.message)，打开开关即可启用", .neutral) }
        return ("未启用 · 完成准备后打开开关", .neutral)
    }
}

/// A plugin as delivered: a folder holding manifest.json, the same folder
/// one level down (as unzipping often leaves it), or a .zip of either.
struct PluginPackage {
    let root: URL
    private let unpacked: URL?

    static func open(_ source: URL) throws -> PluginPackage {
        guard source.pathExtension.lowercased() == "zip" else {
            return PluginPackage(root: try locateRoot(in: source), unpacked: nil)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tact-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try unzip(source, into: folder)
            return PluginPackage(root: try locateRoot(in: folder), unpacked: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func close() {
        if let unpacked { try? FileManager.default.removeItem(at: unpacked) }
    }

    private static func locateRoot(in folder: URL) throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        let folders = children.filter {
            $0.lastPathComponent != "__MACOSX" && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if folders.count == 1, fileManager.fileExists(atPath: folders[0].appendingPathComponent("manifest.json").path) {
            return folders[0]
        }
        throw PlatformError.invalid("没有找到 manifest.json，请选择插件文件夹或它的 .zip 压缩包")
    }

    private static func unzip(_ archive: URL, into folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PlatformError.invalid("压缩包无法解开") }
    }
}
