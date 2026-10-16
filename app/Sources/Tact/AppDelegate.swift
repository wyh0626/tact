import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: QuickPanelController?
    private var controller: Controller?
    private var windows: WindowManager?
    private var configProblem: String?
    private var launchedAt = Date.distantFuture
    private var languageObserver: NSObjectProtocol?
    private var updateReminder: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LanguageSettings.shared
        NSApp.mainMenu = Self.makeMainMenu()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .tactLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.mainMenu = Self.makeMainMenu()
                self?.windows?.refreshLanguage()
                self?.configProblem = AppConfig.load().1
                self?.controller?.overlay.hide()
            }
        }
        // Opened straight from the disk image: move first, before anything starts.
        if Relocation.offerMove() { return }
        AppConfig.bootstrapIfNeeded()
        AppConfig.refreshUntouchedStyle()
        let (cfg, problem) = AppConfig.load()
        configProblem = problem
        if let problem = problem { Log.info("⚠️ \(problem)") }
        for permission in Permission.allCases where !permission.isGranted {
            Log.info("⚠️ 还没有\(permission.title)权限：系统设置 → 隐私与安全性 → \(permission.title)")
        }

        let c = Controller(config: cfg)
        controller = c
        c.start()
        c.ensureEngine()
        let w = WindowManager(controller: c)
        windows = w
        buildStatusItem()
        Updates.shared.start()
        updateReminder = Updates.shared.$waiting.combineLatest(SuggestionActivity.shared.$kind).sink { [weak self] version, activity in
            let image = MenuBarMark.image(badged: version != nil, activity: activity)
            self?.statusItem?.button?.image = image
            self?.statusItem?.button?.toolTip = image.accessibilityDescription
        }
        Log.info("Tact 已启动：在聊天工具里按 \(c.hotKeyDisplay) 生成建议")
        launchedAt = Date()

        if !OnboardingModel.isCompleted {
            w.showOnboarding()
        } else if !Permission.allCases.allSatisfy(\.isGranted) {
            w.showSettings(pane: .general)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        controller?.shutdown()
    }

    /// Opening Tact again (Finder, Spotlight, `open`) shows its window: on a
    /// full menu bar the icon can sit hidden behind the notch. An app
    /// without a Dock icon gets no reopen event then, only brought forward,
    /// so coming forward with nothing open counts as one. Launching (by
    /// hand, at login, after a rebuild) brings it forward too and opens
    /// nothing.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date().timeIntervalSince(launchedAt) > 2, let windows, !windows.isShowingWindow,
              panel?.isVisible != true else { return }
        if OnboardingModel.isCompleted {
            windows.showSettings()
        } else {
            windows.showOnboarding()
        }
    }

    /// A menu bar app shows no menu bar, but text fields still get ⌘C, ⌘V,
    /// ⌘A and friends only through the main menu's key equivalents; without
    /// it, pasting an API key into the settings window does nothing.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.tr("退出 Tact", "Quit Tact"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Tact", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: L10n.tr("编辑", "Edit"))
        edit.addItem(withTitle: L10n.tr("撤销", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L10n.tr("重做", "Redo"), action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.tr("剪切", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.tr("拷贝", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.tr("粘贴", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.tr("全选", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: L10n.tr("编辑", "Edit"), action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: L10n.tr("窗口", "Window"))
        window.addItem(withTitle: L10n.tr("关闭", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: L10n.tr("窗口", "Window"), action: nil, keyEquivalent: "").submenu = window
        return main
    }

    /// The menu bar icon opens the quick panel on a press, as a menu would.
    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = MenuBarMark.image()
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
        panel = QuickPanelController()
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button, let controller, let windows else { return }
        panel?.toggle(from: button) {
            let model = windows.settingsModelForPanel()
            model.refreshStatus()
            let file = (try? ConfigFile.load(from: AppConfig.configPath)) ?? ConfigFile(root: [:])
            let actions = QuickPanelActions(
                openSettings: { [weak self] pane in
                    self?.panel?.hide()
                    self?.windows?.showSettings(pane: pane)
                },
                openOnboarding: { [weak self] in
                    self?.panel?.hide()
                    self?.windows?.showOnboarding()
                },
                quit: { NSApp.terminate(nil) },
                speedSaved: { [weak self] speed in self?.windows?.openSettingsModel?.modelSettings.adoptSpeed(from: speed) })
            let speed = ModelSettings(file: file)
            return AnyView(LocalizedContent { QuickPanelView(settings: model, platforms: model.platformSettings, speed: speed,
                                          status: QuickPanelStatus(hotkey: controller.hotKeyDisplay,
                                                                   problem: controller.hotKeyProblem ?? self.configProblem),
                                          actions: actions) })
        }
    }
}
