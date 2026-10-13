import SwiftUI

enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, model, practice, chat, done

    var title: String {
        switch self {
        case .welcome: return "欢迎"
        case .permissions: return "授权"
        case .model: return "模型"
        case .practice: return "试一试"
        case .chat: return "聊天工具"
        case .done: return "完成"
        }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    let controller: Controller
    let modelSettings: ModelSettings
    let platformSettings: PlatformSettings
    let practice: PracticeChat
    var onFinish: () -> Void = {}

    @Published var step: OnboardingStep {
        didSet { UserDefaults.standard.set(step.rawValue, forKey: Self.stepKey) }
    }
    @Published private(set) var permissions: [Permission: Bool] = [:]
    /// Granted during this run: screen recording needs a relaunch to apply.
    @Published private(set) var grantedThisRun = false
    @Published var launchAtLogin = LoginItem.isEnabled

    private var timer: Timer?
    static let stepKey = "onboarding.step"
    static let completedKey = "onboarding.completed"

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    init(controller: Controller) {
        self.controller = controller
        let file = (try? ConfigFile.load(from: AppConfig.configPath)) ?? ConfigFile(root: [:])
        modelSettings = ModelSettings(file: file)
        platformSettings = PlatformSettings(controller: controller, file: file)
        practice = PracticeChat(hotkey: controller.hotKeyDisplay, overlay: controller.overlay,
                                suggest: { [weak controller] in await controller?.practiceSuggestion($0) })
        step = OnboardingStep(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .welcome
        refreshPermissions()
    }

    var allPermissionsGranted: Bool { Permission.allCases.allSatisfy { permissions[$0] == true } }

    func startWatchingPermissions() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    func stopWatchingPermissions() {
        timer?.invalidate()
        timer = nil
    }

    func refreshPermissions() {
        let now = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, $0.isGranted) })
        if now.contains(where: { $0.value && permissions[$0.key] == false }) { grantedThisRun = true }
        permissions = now
    }

    func next() {
        guard let following = OnboardingStep(rawValue: step.rawValue + 1) else { return finish() }
        step = following
    }

    func back() {
        if let previous = OnboardingStep(rawValue: step.rawValue - 1) { step = previous }
    }

    func setLaunchAtLogin(_ on: Bool) {
        _ = LoginItem.set(on)
        launchAtLogin = LoginItem.isEnabled
    }

    func finish() {
        stopWatchingPermissions()
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        onFinish()
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var platformSettings: PlatformSettings

    init(model: OnboardingModel) { self.model = model; platformSettings = model.platformSettings }

    var body: some View {
        HStack(spacing: 0) {
            OnboardingHero(step: model.step)
                .frame(width: 300)
                .animation(Motion.spring, value: model.step)
            VStack(alignment: .leading, spacing: 0) {
                // Steps can outgrow the window (the model step after signing in);
                // the content scrolls and the footer stays put.
                ScrollView {
                    content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 44).padding(.horizontal, 40).padding(.bottom, 20)
                        // Each step slides in a little and fades; the old one just fades.
                        .id(model.step)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
                }
                .animation(Motion.spring, value: model.step)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                footer
                    .padding(.top, 16)
                    .padding(.horizontal, 40).padding(.bottom, 28)
            }
            .background(Theme.canvas)
        }
        .frame(width: 860, height: 620)
        .tint(Theme.accent)
        .onAppear { model.startWatchingPermissions() }
        .onDisappear { model.stopWatchingPermissions() }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep(model: model)
        case .model: ModelStep(model: model, settings: model.modelSettings)
        case .practice: PracticeStep(practice: model.practice, controller: model.controller,
                                     keyboardReady: model.permissions[.accessibility] == true)
        case .chat: ChatStep(model: model)
        case .done: DoneStep(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome {
                Button("上一步") { model.back() }.buttonStyle(SecondaryButtonStyle()).disabled(platformSettings.busy)
            }
            Spacer()
            if model.step == .model {
                FooterTestResult(settings: model.modelSettings)
            }
            if let skip = skipTitle {
                Button(skip) { model.next() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(platformSettings.busy)
            }
            Button(primaryTitle) { primaryAction() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!primaryEnabled)
                // Return sends in the practice chat; it must not leave the step.
                .keyboardShortcut(model.step == .practice ? nil : .defaultAction)
        }
    }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: return "开始设置"
        case .model: return model.modelSettings.testState == .testing ? "测试中…" : "测试并继续"
        case .done: return "开始使用"
        default: return "继续"
        }
    }

    private var primaryEnabled: Bool {
        guard !platformSettings.busy else { return false }
        switch model.step {
        case .permissions: return model.allPermissionsGranted
        case .model: return model.modelSettings.testState != .testing
        default: return true
        }
    }

    /// On the model step the primary button saves and tests the choice, and
    /// moves on once the test passes.
    private func primaryAction() {
        guard model.step == .model else { return model.next() }
        Task {
            await model.modelSettings.saveAndTest(controller: model.controller)
            if case .passed = model.modelSettings.testState { model.next() }
        }
    }

    private var skipTitle: String? {
        switch model.step {
        case .permissions, .model, .chat: return "稍后再说"
        case .practice: return model.practice.finished ? nil : "跳过"
        default: return nil
        }
    }
}

private struct OnboardingHero: View {
    let step: OnboardingStep

    var body: some View {
        ZStack(alignment: .topLeading) {
            DitherArtView(layout: .hero)
            VStack(alignment: .leading, spacing: 0) {
                AppIconImage().frame(width: 60, height: 60)
                Text("Tact").font(Theme.display(26)).foregroundStyle(.white).padding(.top, 20)
                Text("不知道怎么回？\n按快捷键就好。")
                    .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(3).padding(.top, 8)
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(OnboardingStep.allCases, id: \.self) { item in
                        StepMarker(item: item, current: step)
                    }
                }
            }
            .padding(.horizontal, 30).padding(.top, 56).padding(.bottom, 32)
        }
    }
}

private struct StepMarker: View {
    let item: OnboardingStep
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", item.rawValue + 1))
                .font(Theme.mono(11))
                .foregroundStyle(.white.opacity(item == current ? 1 : 0.4))
            Rectangle()
                .fill(item == current ? Theme.accent : .white.opacity(item.rawValue < current.rawValue ? 0.55 : 0.18))
                .frame(width: item == current ? 18 : 10, height: 1.5)
            Text(item.title).font(.system(size: 13, weight: item == current ? .medium : .regular))
                .foregroundStyle(.white.opacity(item == current ? 1 : (item.rawValue < current.rawValue ? 0.6 : 0.4)))
        }
    }
}

struct StepTitle: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: eyebrow)
            Text(title).font(Theme.display(24)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 13.5)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            StepTitle(eyebrow: "Tact", title: "看懂对话，\n替你起草回复",
                      detail: "Tact 待在菜单栏里。不知道怎么回时按快捷键，它根据最近的聊天起草一句回复，放进输入框，发不发由你决定。")
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "control", title: "双击 ⌃ 生成",
                        detail: "输入框空着就起草整句回复；写了几个字，就按你的意思把话说完整")
                Feature(symbol: "arrow.right.to.line", title: "灰字出现，Tab 接受",
                        detail: "不满意就继续打字或按 Esc，什么都不会发出去")
                Feature(symbol: "lock", title: "数据只在你和你选的模型之间",
                        detail: "没有服务器。也可以用本机模型，聊天内容完全不出电脑")
            }
        }
    }
}

private struct Feature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, size: 32, emphasized: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepTitle(eyebrow: "01 · 授权", title: "打开两个系统权限",
                      detail: "点「去授权」后在系统设置里打开 Tact 的开关。授权状态会自动刷新。")
            VStack(spacing: 12) {
                ForEach(Permission.allCases) { permission in
                    PermissionTile(permission: permission, granted: model.permissions[permission] == true)
                }
            }
            if model.grantedThisRun && AppRelauncher.canRelaunch {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.ink)
                    Text("屏幕录制要重启 Tact 才生效，重启后会回到这一步。").font(.system(size: 12.5))
                    Spacer()
                    Button("立即重启") { AppRelauncher.relaunch() }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
            }
        }
    }
}

private struct PermissionTile: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: permission.symbol, size: 36, tint: granted ? Theme.ok : nil, emphasized: true)
            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
                Text(permission.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted {
                StatusDot(tone: .ok, text: "已授权")
            } else {
                Button("去授权") {
                    permission.request()
                    permission.openSystemSettings()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

private struct ModelStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var settings: ModelSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(eyebrow: "02 · 模型", title: "选一个模型",
                      detail: "云端模型会收到当前会话最近的消息；选「本机」则完全在这台 Mac 上处理。")
            ModelForm(settings: settings, controller: model.controller, compact: true, showsSaveButton: false)
        }
    }
}

private struct ChatStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var settings: PlatformSettings
    @State private var adding: AddChatToolModel?

    init(model: OnboardingModel) { self.model = model; settings = model.platformSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepTitle(eyebrow: "03 · 聊天工具", title: "添加你的聊天工具",
                      detail: "导入这个 IM 的插件，按它的步骤准备好，再打开开关。也可以稍后在设置里添加。")
            ChatToolList(settings: settings, onAdd: add)
            if !settings.entries.isEmpty {
                Button { add() } label: { Label("再添加一个", systemImage: "plus") }
                    .buttonStyle(QuietButtonStyle()).disabled(settings.busy)
            }
            if let problem = settings.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $adding) { AddChatToolSheet(model: $0) }
    }

    private func add() {
        settings.problem = nil
        adding = AddChatToolModel(settings: settings)
    }
}

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject private var settings: PlatformSettings

    init(model: OnboardingModel) { self.model = model; settings = model.platformSettings }

    private var hasChatTool: Bool {
        settings.entries.contains { $0.supported && $0.enabled && $0.supportsSuggestions }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            StepTitle(eyebrow: "04 · 完成", title: hasChatTool ? "去聊天窗口试一下" : "基础设置已完成",
                      detail: hasChatTool ? "打开已接入的聊天工具，点一下输入框，然后：" : "聊天工具尚未接入。拿到插件后，在设置的「聊天工具」页面继续添加、检测并启用。")
            if hasChatTool {
                VStack(alignment: .leading, spacing: 14) {
                    ShortcutLine(keys: [model.controller.hotKeyDisplay], text: "生成一条建议")
                    ShortcutLine(keys: ["Tab"], text: "接受灰字，写进输入框")
                    ShortcutLine(keys: ["Esc"], text: "不要这条建议")
                }
            }
            Card {
                SettingRow(title: "登录时启动", detail: LoginItem.isAvailable ? "开机后自动在菜单栏待命" : "从安装包启动时才能设置",
                           divider: false) {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch).disabled(!LoginItem.isAvailable)
                }
            }
            Text("之后可以在菜单栏的 Tact 图标 → 设置 里修改这些。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutLine: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) { ForEach(keys, id: \.self) { KeyCap(label: $0) } }
                .frame(minWidth: 80, alignment: .leading)
            Text(text).font(.system(size: 13.5))
        }
    }
}

/// The model test result, short enough to sit beside the footer buttons.
private struct FooterTestResult: View {
    @ObservedObject var settings: ModelSettings

    var body: some View {
        TestResult(state: settings.testState).frame(maxWidth: 260, alignment: .trailing)
    }
}
