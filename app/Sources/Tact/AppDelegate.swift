import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: QuickPanelController?
    private var controller: Controller?
    private var windows: WindowManager?
    private var configProblem: String?
    private var launchedAt = Date.distantFuture

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        AppConfig.bootstrapIfNeeded()
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
        Log.info("Tact 已启动：在聊天工具里按 \(c.hotKeyDisplay) 生成建议")
        launchedAt = Date()

        if !OnboardingModel.isCompleted {
            w.showOnboarding()
        } else if !Permission.allCases.allSatisfy(\.isGranted) {
            w.showSettings(pane: .general)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        appMenu.addItem(withTitle: "退出 Tact", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "Tact", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "窗口", action: nil, keyEquivalent: "").submenu = window
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
            return AnyView(QuickPanelView(settings: model, platforms: model.platformSettings, speed: ModelSettings(file: file),
                                          status: QuickPanelStatus(hotkey: controller.hotKeyDisplay,
                                                                   problem: controller.hotKeyProblem ?? self.configProblem),
                                          actions: actions))
        }
    }
}
