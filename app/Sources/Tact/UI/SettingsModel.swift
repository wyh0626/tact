import AppKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, model, chat, style, privacy, stats, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.tr("通用", "General")
        case .model: return L10n.tr("模型", "Model")
        case .chat: return L10n.tr("聊天工具", "Chat tools")
        case .style: return L10n.tr("表达风格", "Writing style")
        case .privacy: return L10n.tr("隐私", "Privacy")
        case .stats: return L10n.tr("统计", "Statistics")
        case .about: return L10n.tr("关于", "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .model: return "sparkle"
        case .chat: return "bubble.left.and.bubble.right"
        case .style: return "quote.bubble"
        case .privacy: return "lock"
        case .stats: return "chart.bar"
        case .about: return "info.circle"
        }
    }
}

/// What starts a suggestion, as offered in settings, the default first.
enum TriggerChoice: String, CaseIterable, Identifiable {
    case doubleControl = "double+ctrl"
    case doubleOption = "double+option"
    case doubleCommand = "double+cmd"
    case doubleShift = "double+shift"
    case combo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doubleControl: return L10n.tr("双击 ⌃ Control（推荐）", "Double ⌃ (recommended)")
        case .doubleOption: return L10n.tr("双击 ⌥ Option", "Double ⌥ Option")
        case .doubleCommand: return L10n.tr("双击 ⌘ Command", "Double ⌘ Command")
        case .doubleShift: return L10n.tr("双击 ⇧ Shift", "Double ⇧ Shift")
        case .combo: return L10n.tr("组合键", "Keyboard shortcut")
        }
    }

    /// What the choice may collide with. A double ⌃ is the one no common
    /// app or input method takes by default.
    var note: String {
        switch self {
        case .doubleControl: return L10n.tr("只有把系统听写设成「按两下 Control」时会冲突（系统设置 → 键盘 → 听写）", "Conflicts if Dictation uses “Press Control Key Twice” (System Settings → Keyboard → Dictation).")
        case .doubleOption: return L10n.tr("Claude 桌面版的快速输入默认就是双击 ⌥，装了 Claude 会一起弹出来", "Claude desktop uses double-press ⌥ for quick entry by default, so it may also open.")
        case .doubleCommand: return L10n.tr("Siri 可以设成「按两下 Command」，开了的话会冲突（系统设置 → Apple 智能与 Siri）", "Conflicts if Siri uses “Press Command Key Twice” (System Settings → Apple Intelligence & Siri).")
        case .doubleShift: return L10n.tr("中文输入法用 ⇧ 切换中英文，连按两下会来回切换，不建议用", "Chinese input methods use ⇧ to switch languages. Pressing it twice toggles back and forth, so this is not recommended.")
        case .combo: return L10n.tr("避开 ⌘Space（聚焦搜索）和 ⌃Space（切换输入法）", "Avoid ⌘Space (Spotlight) and ⌃Space (input source switching).")
        }
    }

    static func from(_ spec: String) -> TriggerChoice {
        let parsed = TriggerSpec.parse(spec)
        return allCases.first { $0 != .combo && TriggerSpec.parse($0.rawValue) == parsed } ?? .combo
    }
}

/// State behind the settings window. Toggles and pickers apply as soon as
/// they change; the model and style panes save with a button because a
/// half-typed value should not restart the engine.
@MainActor
final class SettingsModel: ObservableObject {
    let controller: Controller
    let modelSettings: ModelSettings
    let platformSettings: PlatformSettings

    @Published var pane: SettingsPane = .general
    @Published var problem: String?

    // General
    @Published var trigger: TriggerChoice
    @Published var comboSpec: String
    @Published var insertMethod: InsertMethod
    @Published private(set) var wechat: Bool
    @Published var launchAtLogin: Bool
    @Published var loginItemNote: String?

    // Chat tools
    @Published var historyLimit: Int

    // Style
    @Published var styleText: String
    @Published var styleSaved = true
    let stylePath: String

    // Privacy
    @Published var logPlaintext: Bool

    // Stats
    @Published var stats: StatsData?
    @Published var statsLoading = false

    @Published private(set) var permissions: [Permission: Bool] = [:]
    @Published private(set) var engineConnected = false
    /// False until the first status check answers, so nothing shows the
    /// engine as down before it was asked.
    @Published private(set) var statusChecked = false
    private var statusRefreshTask: Task<Void, Never>?
    /// Set for screenshots, where neither the engine nor the permissions
    /// are there to check.
    private var statusHeld = false

    init(controller: Controller) {
        self.controller = controller
        let file = (try? ConfigFile.load(from: AppConfig.configPath)) ?? ConfigFile(root: [:])
        modelSettings = ModelSettings(file: file)
        platformSettings = PlatformSettings(controller: controller, file: file)
        let hotkey = file.string("app.hotkey") ?? controller.config.hotkey
        trigger = TriggerChoice.from(hotkey)
        comboSpec = TriggerChoice.from(hotkey) == .combo ? hotkey : "ctrl+option+space"
        insertMethod = InsertMethod(rawValue: file.string("app.insert_method") ?? "") ?? .auto
        wechat = file.bool("app.wechat") ?? false
        launchAtLogin = LoginItem.isEnabled
        historyLimit = Int(file.number("context.history_limit") ?? 20)
        stylePath = AppConfig.expand(file.string("style.file") ?? "~/.tact/style.md")
        styleText = (try? String(contentsOfFile: stylePath, encoding: .utf8)) ?? ""
        logPlaintext = file.bool("feedback.log_plaintext") ?? false
        refreshStatus()
    }

    var hotkeySpec: String { trigger == .combo ? comboSpec : trigger.rawValue }

    /// Permission services and a slow engine must never hold up a tab click.
    /// Opening the window and showing General can both request a refresh;
    /// share that work instead of sending two pings.
    @discardableResult
    func refreshStatus() -> Task<Void, Never> {
        if statusHeld { return Task {} }
        if let statusRefreshTask { return statusRefreshTask }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.statusRefreshTask = nil }
            async let grants = Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
            }.value
            async let response = self.controller.engineRequest(["op": "ping"], timeout: 1)
            let (permissions, ping) = await (grants, response)
            guard !self.statusHeld else { return }
            if self.permissions != permissions { self.permissions = permissions }
            let connected = (ping?["ok"] as? Bool) == true
            if self.engineConnected != connected { self.engineConnected = connected }
            if !self.statusChecked { self.statusChecked = true }
        }
        statusRefreshTask = task
        return task
    }

    /// The status of a Mac that is set up, engine running and every
    /// permission granted, held against live checks: for screenshots.
    func showAsSetUp() {
        statusHeld = true
        permissions = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, true) })
        engineConnected = true
        statusChecked = true
    }

    /// Writes app-side settings and applies them to the running controller.
    func applyGeneral() {
        guard TriggerSpec.parse(hotkeySpec) != nil, trigger != .combo || HotKey(spec: comboSpec) != nil else {
            problem = L10n.tr("快捷键写法不对，比如 ctrl+option+space", "Invalid shortcut. Try ctrl+option+space.")
            return
        }
        update { file in
            file.set("app.hotkey", hotkeySpec)
            file.set("app.insert_method", insertMethod.rawValue)
        }
    }

    /// Turning WeChat on asks for screen recording, without which nothing
    /// in its window can be read.
    func setWeChat(_ on: Bool) {
        if on && !Permission.screenRecording.isGranted { Permission.screenRecording.request() }
        wechat = on
        update { $0.set("app.wechat", on) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        loginItemNote = LoginItem.set(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    /// Engine-side settings: written, then the engine restarts to load them.
    func applyEngineSettings() {
        update(restartEngine: true) { file in
            file.set("context.history_limit", historyLimit)
            file.set("feedback.log_plaintext", logPlaintext)
        }
    }

    func saveStyle() {
        do {
            try styleText.write(toFile: stylePath, atomically: true, encoding: .utf8)
            styleSaved = true
            problem = nil
        } catch {
            problem = L10n.tr("保存表达风格失败：\(error.localizedDescription)", "Could not save writing style: \(error.localizedDescription)")
        }
    }

    func loadStats() async {
        statsLoading = true
        stats = await controller.statsData()
        statsLoading = false
    }

    private func update(restartEngine: Bool = false, _ change: (inout ConfigFile) -> Void) {
        do {
            var file = try ConfigFile.load(from: AppConfig.configPath)
            change(&file)
            try file.write(to: AppConfig.configPath)
            let (config, configProblem) = AppConfig.load()
            controller.apply(config)
            problem = configProblem ?? controller.hotKeyProblem
        } catch {
            problem = L10n.tr("保存配置失败：\(error.localizedDescription)", "Could not save configuration: \(error.localizedDescription)")
            return
        }
        guard restartEngine else { return }
        Task {
            if !(await controller.restartEngine()) {
                problem = controller.engineRestartProblem()
            }
            refreshStatus()
        }
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppConfig.directory))
    }
}
