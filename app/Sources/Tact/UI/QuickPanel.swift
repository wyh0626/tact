import AppKit
import SwiftUI

/// What the panel shows besides the settings state, read when it opens.
struct QuickPanelStatus {
    let hotkey: String
    let problem: String?
}

struct QuickPanelActions {
    let openSettings: (SettingsPane?) -> Void
    let openOnboarding: () -> Void
    let quit: () -> Void
    /// A speed choice was saved from the panel.
    let speedSaved: (ModelSettings) -> Void
}

/// The panel that drops from the menu bar icon: a frosted, borderless window
/// under the icon. It closes on Esc, on a click anywhere else, or on the
/// icon again, and keeps its top edge under the icon as its content grows.
@MainActor
final class QuickPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 320

    private let panel: QuickPanelWindow
    private let host: NSHostingView<AnyView>
    private var anchor = CGRect.zero
    private var visibleFrame = CGRect.zero
    private var clickMonitor: Any?
    private var hiddenAt = Date.distantPast
    /// The content's last measured height, the first guess for the next open.
    private var contentHeight: CGFloat = 420
    /// Opened but not yet measured: shown once the content reports its size.
    private var revealPending = false

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = QuickPanelWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Self.roundedMask(radius: 12)
        // The panel sizes the host; the host must never size itself, or a
        // taller content grows it past the panel's top edge.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        backdrop.addSubview(host)
        panel.contentView = backdrop
    }

    /// Opens the panel under `button`, or closes it when it is open.
    func toggle(from button: NSStatusBarButton, content: () -> AnyView) {
        if panel.isVisible { return hide() }
        // A click on the icon that took focus from the open panel has just
        // closed it; that click must not open it again.
        guard Date().timeIntervalSince(hiddenAt) > 0.3 else { return }
        show(from: button, content: content())
    }

    func hide() {
        guard panel.isVisible else { return }
        hiddenAt = Date()
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        let finish = { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            // Drop the content so the settings state it holds goes with it.
            self.host.rootView = AnyView(EmptyView())
        }
        if Motion.reduced { return finish() }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func show(from button: NSStatusBarButton, content: AnyView) {
        guard let window = button.window else { return }
        anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        // The content reports its own height; the panel follows it with its
        // top edge kept under the icon, and the content stays pinned to the
        // top while the panel grows or shrinks.
        host.rootView = AnyView(Self.pinnedToTop(content.frame(width: Self.width)) { [weak self] height in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.contentHeightChanged(height) } }
        })
        revealPending = true
        panel.alphaValue = 0
        place(height: contentHeight, animated: false)
        panel.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Show it even if a measurement never arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.reveal() }
        // Clicks in other apps never reach this one; watch for them.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard panel.isVisible, height > 0 else { return }
        contentHeight = height
        place(height: height, animated: !revealPending)
        reveal()
    }

    private func reveal() {
        guard revealPending else { return }
        revealPending = false
        if Motion.reduced { panel.alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func place(height: CGFloat, animated: Bool) {
        let target = Self.frame(size: CGSize(width: Self.width, height: height), below: anchor, within: visibleFrame)
        guard target != panel.frame else { return }
        if animated && !Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
        panel.invalidateShadow()
    }

    /// The content at its own height, pinned to the top of a host of any
    /// size, reporting that height as it changes.
    static func pinnedToTop<Content: View>(_ content: Content, height: @escaping (CGFloat) -> Void) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { Color.clear.preference(key: PanelHeightKey.self, value: $0.size.height) })
            .onPreferenceChange(PanelHeightKey.self, perform: height)
            // A zero minimum keeps this frame the host's size; without it the
            // frame takes the content's height and the host centres it,
            // pushing the top out of the panel.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    /// Centred under the icon, kept inside the screen's visible area with a
    /// margin, and never taller than the room below the menu bar.
    static func frame(size: CGSize, below anchor: CGRect, within visible: CGRect) -> CGRect {
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        let top = min(anchor.minY, visible.maxY) - gap
        let height = min(size.height, max(0, top - visible.minY - margin))
        let x = min(max(anchor.midX - size.width / 2, visible.minX + margin), visible.maxX - margin - size.width)
        return CGRect(x: x.rounded(), y: (top - height).rounded(), width: size.width, height: height.rounded())
    }

    /// A stretchable rounded-rectangle mask: a frosted view clips its blur to
    /// it, which a layer corner radius doesn't do.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class QuickPanelWindow: NSPanel {
    var onCancel: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The panel's content: whether Tact is ready, the chat tools with
/// their switches, the model with its speed, and the way to everything else.
struct QuickPanelView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var platforms: PlatformSettings
    @ObservedObject var speed: ModelSettings
    let status: QuickPanelStatus
    let actions: QuickPanelActions
    @ObservedObject var updates = Updates.shared
    @State private var savingSpeed = false
    @State private var speedProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusLine
            if let version = updates.waiting { update(version) }
            chatTools
            model
            footer
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
        .animation(Motion.spring, value: platforms.entries.map(\.id))
        .animation(Motion.spring, value: speed.speedOptions.levels.map(\.effort))
        .animation(Motion.quick, value: settings.statusChecked)
        .task {
            guard speed.provider.usesSignIn else { return }
            await speed.refreshChatGPT(controller: settings.controller)
            speed.reconcileSpeed()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppIconImage().frame(width: 22, height: 22)
            Text("Tact").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Button { actions.openSettings(nil) } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut(",", modifiers: .command)
            .help(L10n.tr("设置", "Settings"))
            .accessibilityLabel(L10n.tr("设置", "Settings"))
        }
    }

    private var statusLine: some View {
        let missing = Permission.allCases.first { settings.permissions[$0] == false }
        let (tone, text): (StatusTone, String) = {
            if !settings.statusChecked { return (.neutral, L10n.tr("正在检查…", "Checking…")) }
            if !settings.engineConnected { return (.warn, L10n.tr("引擎没有连接", "Engine disconnected")) }
            if let missing { return (.warn, L10n.tr("还没有\(missing.title)权限", "\(missing.title) access is missing")) }
            if let problem = status.problem { return (.warn, problem) }
            return (.ok, L10n.tr("正在待命 · \(status.hotkey) 生成建议", "Ready · \(status.hotkey) to suggest"))
        }()
        return HStack(spacing: 8) {
            StatusDot(tone: tone, text: text, lineLimit: 2)
                .contentTransition(.opacity)
            Spacer(minLength: 8)
            if let missing, settings.statusChecked {
                Button(L10n.tr("去授权", "Grant access")) {
                    missing.request()
                    missing.openSystemSettings()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, 4)
    }

    /// A version a background check found. Sparkle's window, which this
    /// opens, says what changed and installs it.
    private func update(_ version: String) -> some View {
        Card {
            Button { updates.check() } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: "arrow.down.circle", size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.tr("有新版本 \(version)", "Tact \(version) is available"))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(L10n.tr("看看改了什么，再决定装不装", "See what’s new before installing"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    /// A built-in app is listed once it is on, or while it is installed and
    /// could be.
    private static let installed = Set(BuiltInApp.allCases.filter(\.isInstalled))
    private var builtIns: [BuiltInApp] {
        BuiltInApp.allCases.filter { platforms.builtIn.contains($0) || Self.installed.contains($0) }
    }

    private func state(of app: BuiltInApp) -> (StatusTone, String) {
        if !platforms.builtIn.contains(app) { return (.neutral, L10n.tr("未启用", "Disabled")) }
        if settings.permissions[.screenRecording] == false { return (.warn, L10n.tr("需要屏幕录制权限", "Needs Screen Recording access")) }
        if app == .dingtalk { return (.ok, L10n.tr("已启用 · 辅助功能读取", "Enabled · Accessibility")) }
        return (.ok, L10n.tr("已启用 · 截图识别", "Enabled · screen recognition"))
    }

    private var chatTools: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: L10n.tr("聊天工具", "Chat tools")).padding(.horizontal, 4)
            Card {
                ForEach(Array(builtIns.enumerated()), id: \.element) { index, app in
                    QuickToolRow(name: app.name, tone: state(of: app).0, status: state(of: app).1, enabled: platforms.builtIn.contains(app),
                                 checking: false, toggleDisabled: false,
                                 open: { actions.openSettings(.chat) },
                                 setEnabled: { on in withAnimation(Motion.quick) { platforms.set(app, on: on) } })
                    if index < builtIns.count - 1 || !platforms.entries.isEmpty { RowDivider(inset: 46) }
                }
                if platforms.entries.isEmpty && builtIns.isEmpty {
                    Button { actions.openSettings(.chat) } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: "plus", size: 24)
                            Text(L10n.tr("添加聊天工具", "Add a chat app")).font(.system(size: 13)).foregroundStyle(Theme.ink)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                    .buttonStyle(RowButtonStyle())
                } else {
                    ForEach(Array(platforms.entries.enumerated()), id: \.element.id) { index, entry in
                        QuickToolRow(name: entry.name, tone: entry.tone, status: entry.status, enabled: entry.enabled,
                                     checking: platforms.checkingID == entry.id,
                                     toggleDisabled: platforms.busy || !entry.supported && !entry.enabled,
                                     open: { actions.openSettings(.chat) },
                                     setEnabled: { setEnabled($0, entry: entry) })
                        if index < platforms.entries.count - 1 { RowDivider(inset: 46) }
                    }
                }
            }
        }
    }

    private var model: some View {
        let options = speed.speedOptions
        return VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: L10n.tr("模型", "Model")).padding(.horizontal, 4)
            Card {
                Button { actions.openSettings(.model) } label: {
                    HStack(spacing: 10) {
                        IconTile(symbol: ModelProvider.cards.first { $0.id == speed.provider.cardID }?.symbol ?? speed.provider.symbol,
                                 size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(speed.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(method).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
                .buttonStyle(RowButtonStyle())
                if !options.levels.isEmpty {
                    RowDivider(inset: 12)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(L10n.tr("推理", "Reasoning")).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                                .fixedSize()
                            Spacer(minLength: 8)
                            reasoningPicker
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.tr("推理", "Reasoning")).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                            reasoningPicker.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                if options.fastTier != nil {
                    RowDivider(inset: 12)
                    HStack(spacing: 8) {
                        Text(L10n.tr("快速模式", "Fast mode")).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        Toggle(L10n.tr("快速模式", "Fast mode"), isOn: Binding(get: { speed.fastMode }, set: { speed.fastMode = $0; saveSpeed() }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .disabled(savingSpeed)
            if savingSpeed {
                Text(L10n.tr("正在应用…", "Applying…")).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else if let speedProblem {
                Text(speedProblem).font(.system(size: 11.5)).foregroundStyle(Theme.warn).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var reasoningPicker: some View {
        Picker(L10n.tr("推理", "Reasoning"), selection: Binding(get: { speed.reasoningEffort },
                                                         set: { speed.reasoningEffort = $0; saveSpeed() })) {
            ForEach(speed.speedOptions.levels, id: \.self) { Text($0.label).tag($0.effort) }
        }
        .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        .fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 2) {
            Button(L10n.tr("使用引导", "Setup guide"), action: actions.openOnboarding).buttonStyle(QuietButtonStyle())
            Button(L10n.tr("统计", "Stats")) { actions.openSettings(.stats) }.buttonStyle(QuietButtonStyle())
            Spacer()
            Button(L10n.tr("退出", "Quit"), action: actions.quit).buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, -2)
    }

    private var method: String {
        if speed.provider.usesSignIn { return L10n.tr("ChatGPT 账号", "ChatGPT account") }
        if speed.usesOpenAI { return "API Key" }
        return speed.provider.detail
    }

    private func setEnabled(_ on: Bool, entry: PlatformEntry) {
        platforms.problem = nil
        if on {
            Task { await platforms.checkAndEnable(id: entry.id) }
        } else {
            platforms.setEnabled(false, id: entry.id)
        }
    }

    private func saveSpeed() {
        savingSpeed = true
        speedProblem = nil
        Task {
            let saved = await speed.saveSpeed(controller: settings.controller)
            savingSpeed = false
            if saved {
                actions.speedSaved(speed)
            } else {
                speedProblem = speed.chatgptMessage ?? settings.controller.engineRestartProblem()
            }
        }
    }
}

/// A chat tool in the panel: its name and state, and its switch. The row
/// itself leads to the chat tools page.
private struct QuickToolRow: View {
    let name: String
    let tone: StatusTone
    let status: String
    let enabled: Bool
    let checking: Bool
    let toggleDisabled: Bool
    let open: () -> Void
    let setEnabled: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Monogram(name: name, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        StatusDot(tone: tone, text: status)
                            .contentTransition(.opacity)
                            .animation(Motion.quick, value: status)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            if checking { ProgressView().controlSize(.small).transition(.opacity) }
            Toggle(L10n.tr("启用 \(name)", "Enable \(name)"), isOn: Binding(get: { enabled }, set: setEnabled))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(toggleDisabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovering ? Theme.hover : .clear)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: checking)
    }
}
