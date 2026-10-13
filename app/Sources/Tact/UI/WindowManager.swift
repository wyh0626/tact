import AppKit
import SwiftUI

/// Opens the settings and onboarding windows. The app has no Dock icon, so
/// it brings itself forward when it shows one.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let controller: Controller
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var onboardingWindow: NSWindow?

    init(controller: Controller) {
        self.controller = controller
    }

    func showSettings(pane: SettingsPane? = nil) {
        if settingsWindow == nil {
            let model = SettingsModel(controller: controller)
            settingsModel = model
            settingsWindow = makeWindow(SettingsView(model: model), title: "Tact 设置")
        }
        if let pane { settingsModel?.pane = pane }
        settingsModel?.refreshStatus()
        present(settingsWindow)
    }

    /// The settings state the menu bar panel works on: the open window's, so
    /// a switch flipped in one shows in the other, or else a fresh read.
    func settingsModelForPanel() -> SettingsModel {
        settingsModel ?? SettingsModel(controller: controller)
    }

    /// The open settings window's state, if there is one.
    var openSettingsModel: SettingsModel? { settingsModel }

    var isShowingWindow: Bool { settingsWindow?.isVisible == true || onboardingWindow?.isVisible == true }

    func showOnboarding() {
        if onboardingWindow == nil {
            let model = OnboardingModel(controller: controller)
            model.onFinish = { [weak self] in self?.onboardingWindow?.close() }
            onboardingWindow = makeWindow(OnboardingView(model: model), title: "欢迎使用 Tact")
        }
        present(onboardingWindow)
    }

    private func makeWindow<V: View>(_ view: V, title: String) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.delegate = self
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop closed windows so the next open starts from fresh state.
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
            settingsModel = nil
        } else if window === onboardingWindow {
            onboardingWindow = nil
        }
        // Hand the front back to the app in use, so opening Tact again
        // brings it forward and shows its window.
        if !isShowingWindow { NSApp.deactivate() }
    }
}
