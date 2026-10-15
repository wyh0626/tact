import AppKit

/// Chat apps Tact reads by itself: switched on in settings, never imported
/// as plugins. Each is a platform the engine knows by the same id.
enum BuiltInApp: String, CaseIterable, Identifiable, Sendable {
    case wechat, dingtalk

    var id: String { rawValue }
    var platformID: String { rawValue }
    var configKey: String { "app." + rawValue }

    var name: String {
        switch self {
        case .wechat: return L10n.tr("微信", "WeChat")
        case .dingtalk: return L10n.tr("钉钉", "DingTalk")
        }
    }

    /// DingTalk's Mac App Store build has its team in front of its id.
    var bundleIDs: [String] {
        switch self {
        case .wechat: return [WeChatScreen.bundleID]
        case .dingtalk: return DingTalkScreen.bundleIDs
        }
    }

    /// How Tact reads it, for its row in settings.
    var detail: String {
        switch self {
        case .wechat:
            return L10n.tr("定位当前聊天区，在本机识别文字和位置，再交给所选 AI 理解并生成建议。只读取窗口内可见内容。",
                           "Finds the current chat area and recognizes text and positions on your Mac, then sends the text to your selected AI. Only visible window content is read.")
        case .dingtalk:
            return L10n.tr("通过辅助功能读取当前会话、消息和输入框，读不到时改为截图识别。只读取窗口里已加载的消息。",
                           "Reads the open chat, its messages and the input through Accessibility, falling back to screen recognition. Only messages the window has loaded are read.")
        }
    }

    static func app(bundleID: String?) -> BuiltInApp? {
        guard let bundleID else { return nil }
        return allCases.first { $0.bundleIDs.contains(bundleID) }
    }

    var isInstalled: Bool {
        bundleIDs.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}
