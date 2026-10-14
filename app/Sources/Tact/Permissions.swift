import AppKit
import ServiceManagement

/// The two system permissions the app needs, as onboarding and settings
/// present them.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: return L10n.tr("辅助功能", "Accessibility")
        case .screenRecording: return L10n.tr("屏幕录制", "Screen Recording")
        }
    }

    var reason: String {
        switch self {
        case .accessibility: return L10n.tr("读取输入框里的文字和光标位置，按 Tab 时把建议写进去", "Read the input text and cursor position, and insert suggestions when you press Tab.")
        case .screenRecording: return L10n.tr("截取聊天窗口，在本机认出当前是哪个会话；微信的消息也靠它读取", "Capture the chat window to identify the current conversation locally and read WeChat messages.")
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: return "accessibility"
        case .screenRecording: return "rectangle.dashed.badge.record"
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: return AX.isTrusted(prompt: false)
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// Shows the system prompt, which also adds the app to the list in
    /// System Settings so the user only has to flip the switch.
    func request() {
        switch self {
        case .accessibility: _ = AX.isTrusted(prompt: true)
        case .screenRecording: _ = CGRequestScreenCaptureAccess()
        }
    }

    func openSystemSettings() {
        let anchor = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Launch at login through SMAppService, which only works for the app bundle.
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { isAvailable && SMAppService.mainApp.status == .enabled }

    /// Returns a message for the user when the change did not go through.
    static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return L10n.tr("从安装包（Tact.app）启动时才能设置开机启动", "Launch Tact.app to configure launch at login.") }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            if SMAppService.mainApp.status == .requiresApproval {
                return L10n.tr("需要在 系统设置 → 通用 → 登录项 里允许 Tact", "Allow Tact in System Settings → General → Login Items.")
            }
            return nil
        } catch {
            return L10n.tr("设置开机启动失败：\(error.localizedDescription)", "Could not change launch at login: \(error.localizedDescription)")
        }
    }
}

enum AppRelauncher {
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and opens the app bundle again once this process has exited, so
    /// two copies never share the engine socket. Screen recording permission
    /// only takes effect after a restart.
    static func relaunch() {
        guard canRelaunch else { return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
                            "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            Log.info("⚠️ 重启失败：\(error.localizedDescription)")
        }
    }
}
