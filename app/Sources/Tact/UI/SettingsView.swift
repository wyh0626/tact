import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 212)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            SettingsPaneHost(model: model)
        }
        .frame(width: 880, height: 620)
        .background(Theme.canvas)
        .tint(Theme.accent)
    }
}

/// Create a page on its first visit and keep its hosting view for this
/// window's lifetime. Switching back preserves the scroll position, editor
/// and Metal view instead of rebuilding their AppKit controls.
private struct SettingsPaneHost: NSViewRepresentable {
    @ObservedObject var model: SettingsModel

    func makeNSView(context: Context) -> SettingsPaneContainer {
        let container = SettingsPaneContainer()
        // Once the window has settled, build the other pages ahead of the
        // first click on them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak container, weak model] in
            guard let container, let model else { return }
            container.prewarm(model: model)
        }
        return container
    }

    func updateNSView(_ view: SettingsPaneContainer, context: Context) {
        view.show(model.pane, model: model)
    }
}

@MainActor
final class SettingsPaneContainer: NSView {
    private var pages: [SettingsPane: NSHostingView<SettingsPaneContent>] = [:]
    private(set) var selectedPane: SettingsPane?

    func show(_ pane: SettingsPane, model: SettingsModel) {
        guard selectedPane != pane else { return }
        let page = self.page(pane, model: model)
        // A brief crossfade instead of a cut; none on the first page shown.
        if selectedPane != nil, !Motion.reduced {
            wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(fade, forKey: "pane")
        }
        // Only the visible page participates in layout and hit testing.
        subviews.forEach { $0.removeFromSuperview() }
        page.frame = bounds
        addSubview(page)
        selectedPane = pane
    }

    /// A page's first layout and draw create its AppKit controls: tens of
    /// milliseconds for the Model page's fields and pickers. Do that for the
    /// pages not built yet, behind the visible one, one per turn of the run
    /// loop, heaviest first.
    func prewarm(model: SettingsModel) {
        let order: [SettingsPane] = [.model, .chat, .style, .privacy, .stats, .about, .general]
        warm(order.filter { pages[$0] == nil }[...], model: model)
    }

    private func warm(_ panes: ArraySlice<SettingsPane>, model: SettingsModel) {
        guard let pane = panes.first else { return }
        DispatchQueue.main.async { [weak self, weak model] in
            guard let self, let model, self.window != nil else { return }
            if self.pages[pane] == nil {
                let page = self.page(pane, model: model)
                page.frame = self.bounds
                self.addSubview(page, positioned: .below, relativeTo: nil)
                page.layoutSubtreeIfNeeded()
                page.displayIfNeeded()
                page.removeFromSuperview()
            }
            self.warm(panes.dropFirst(), model: model)
        }
    }

    private func page(_ pane: SettingsPane, model: SettingsModel) -> NSHostingView<SettingsPaneContent> {
        if let cached = pages[pane] { return cached }
        let page = NSHostingView(rootView: SettingsPaneContent(model: model, selection: pane))
        page.sizingOptions = []
        page.autoresizingMask = [.width, .height]
        pages[pane] = page
        return page
    }
}

private struct SettingsPaneContent: View {
    @ObservedObject var model: SettingsModel
    let selection: SettingsPane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pane
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.warn)
                }
            }
            .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 36)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .tint(Theme.accent)
    }

    @ViewBuilder private var pane: some View {
        switch selection {
        case .general: GeneralPane(model: model)
        case .model: ModelPane(settings: model.modelSettings, controller: model.controller)
        case .chat: ChatToolsPane(model: model)
        case .style: StylePane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .stats: StatsPane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var model: SettingsModel
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                AppIconImage().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tact").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    StatusDot(tone: model.engineConnected ? .ok : .warn, text: model.engineConnected ? L10n.tr("引擎已连接", "Engine connected") : L10n.tr("引擎未连接", "Engine disconnected"))
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 8).padding(.top, 44).padding(.bottom, 18)

            ForEach(SettingsPane.allCases) { pane in
                SidebarRow(pane: pane, selected: model.pane == pane, selection: selection) {
                    withAnimation(Motion.spring) { model.pane = pane }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

/// A page in the sidebar. The selection is one shape that slides from row
/// to row; other rows wash under the pointer.
private struct SidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12.5))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                Text(pane.title).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Color.primary.opacity(0.78))
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.selection)
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.hover)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        // The selected row already shows where you are; the keyboard focus
        // ring would look like a second selection.
        .focusEffectDisabled()
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var language = LanguageSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StatusCard(model: model)

            Card(title: L10n.tr("语言", "Language")) {
                SettingRow(title: L10n.tr("显示语言", "Display language"),
                           detail: L10n.tr("更改界面语言，不影响回复语言或表达风格。", "Changes the interface language. Reply language and writing style stay as configured."),
                           divider: false) {
                    Picker(L10n.tr("语言", "Language"), selection: $language.selection) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }

            Card(title: L10n.tr("触发", "Trigger")) {
                SettingRow(title: L10n.tr("生成建议", "Generate suggestions"), detail: L10n.tr("只在已启用的聊天工具在前台时生效。", "Only active when an enabled chat app is in the foreground. ") + model.trigger.note,
                           divider: model.trigger == .combo) {
                    Picker("", selection: $model.trigger) {
                        ForEach(TriggerChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 240)
                }
                if model.trigger == .combo {
                    SettingRow(title: L10n.tr("组合键", "Keyboard shortcut"), detail: L10n.tr("比如 ctrl+option+space、ctrl+shift+g", "For example, ctrl+option+space or ctrl+shift+g"), divider: false) {
                        TextField("", text: $model.comboSpec).frame(width: 170)
                            .onSubmit { model.applyGeneral() }
                    }
                }
            }
            .onChange(of: model.trigger) { _, _ in model.applyGeneral() }

            Card(title: L10n.tr("写入", "Insertion")) {
                SettingRow(title: L10n.tr("写入方式", "Insert using"), detail: insertDetail, divider: false) {
                    Picker("", selection: $model.insertMethod) {
                        Text(L10n.tr("自动", "Auto")).tag(InsertMethod.auto)
                        Text(L10n.tr("总是粘贴", "Paste")).tag(InsertMethod.paste)
                        Text(L10n.tr("辅助功能", "Accessibility")).tag(InsertMethod.ax)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
            }
            .onChange(of: model.insertMethod) { _, _ in model.applyGeneral() }

            Card(title: L10n.tr("启动", "Startup")) {
                SettingRow(title: L10n.tr("登录时启动", "Launch at login"), detail: model.loginItemNote ?? L10n.tr("开机后自动在菜单栏待命", "Ready in the menu bar when you log in"), divider: false) {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(!LoginItem.isAvailable)
                }
            }

            PermissionsCard(model: model)
        }
    }

    private var insertDetail: String {
        switch model.insertMethod {
        case .auto: return L10n.tr("英文键盘下短句逐字输入、不碰剪贴板；开着中文输入法或句子较长时粘贴", "Types short replies with a Latin keyboard; pastes longer replies or when a Chinese input method is active.")
        case .paste: return L10n.tr("总是通过剪贴板粘贴，之后恢复原来的剪贴板", "Pastes via the clipboard, then restores its previous contents.")
        case .ax: return L10n.tr("直接写入输入框，个别应用可能察觉不到变化", "Writes directly to the input field. Some apps may not detect the change.")
        }
    }
}

/// Whether Tact is ready, and the three keys that drive it.
private struct StatusCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    status.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 12)
                    shortcuts
                }
                VStack(alignment: .leading, spacing: 14) {
                    status
                    shortcuts
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var status: some View {
        HStack(spacing: 14) {
            AppIconImage().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.engineConnected ? L10n.tr("正在待命", "Ready") : L10n.tr("引擎没有连接", "Engine disconnected"))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                StatusDot(tone: model.engineConnected ? .ok : .warn,
                          text: model.engineConnected ? L10n.tr("在聊天输入框里按快捷键", "Press the shortcut in a chat input") : L10n.tr("会自动重连；一直断开请看 engine.log", "Reconnecting automatically. Check engine.log if this persists."))
            }
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 12) {
            shortcut(keys: triggerKeys, label: L10n.tr("生成", "Generate"))
            shortcut(keys: ["Tab"], label: L10n.tr("接受", "Accept"))
            shortcut(keys: ["Esc"], label: L10n.tr("取消", "Dismiss"))
        }
        .fixedSize()
    }

    private var triggerKeys: [String] {
        switch model.trigger {
        case .doubleControl: return ["⌃", "⌃"]
        case .doubleOption: return ["⌥", "⌥"]
        case .doubleCommand: return ["⌘", "⌘"]
        case .doubleShift: return ["⇧", "⇧"]
        case .combo: return [model.comboSpec]
        }
    }

    private func shortcut(keys: [String], label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in KeyCap(label: key) }
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 2)
        }
    }
}

private struct PermissionsCard: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card(title: L10n.tr("权限", "Permissions")) {
            ForEach(Array(Permission.allCases.enumerated()), id: \.element) { index, permission in
                SettingRow(title: permission.title, detail: permission.reason, divider: index < Permission.allCases.count - 1) {
                    if model.permissions[permission] == true {
                        StatusDot(tone: .ok, text: L10n.tr("已授权", "Granted"))
                    } else {
                        Button(L10n.tr("去授权", "Grant access")) {
                            permission.request()
                            permission.openSystemSettings()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .onAppear { model.refreshStatus() }
    }
}

// MARK: - Model

/// Provider cards plus endpoint, model and key fields; also used in
/// onboarding.
struct ModelForm: View {
    @ObservedObject var settings: ModelSettings
    let controller: Controller
    var compact = false
    /// Onboarding saves from its own footer button instead.
    var showsSaveButton = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ModelProvider.cards) { card in
                    ProviderCard(provider: card, selected: settings.provider.cardID == card.id, compact: compact,
                                 detail: card == .openai ? openAICardDetail : nil) {
                        withAnimation(Motion.spring) { settings.chooseCard(card) }
                    }
                }
            }

            if settings.provider.usesSignIn {
                ChatGPTAccount(settings: settings, controller: controller, compact: compact)
            } else if settings.provider == .local {
                LocalModelsCard(settings: settings, controller: controller, compact: compact)
            } else {
                KeyFields(settings: settings, compact: compact)
            }

            SpeedCard(settings: settings)

            if showsSaveButton {
                HStack(spacing: 12) {
                    Button(settings.testState == .testing ? L10n.tr("测试中…", "Testing…") : L10n.tr("保存并测试连接", "Save and test connection")) {
                        Task { await settings.saveAndTest(controller: controller) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(settings.testState == .testing)
                    TestResult(state: settings.testState)
                }
                .animation(Motion.quick, value: settings.testState)
            }
        }
        .animation(Motion.spring, value: settings.provider)
        .animation(Motion.spring, value: settings.chatgpt)
        .animation(Motion.spring, value: settings.chatgptModels)
        .task { await settings.refreshChatGPT(controller: controller) }
        .onChange(of: settings.model) { _, _ in settings.reconcileSpeed() }
        .onChange(of: settings.chatgptModels) { _, _ in settings.reconcileSpeed() }
    }

    private var openAICardDetail: String {
        if settings.provider.usesSignIn, let status = settings.chatgpt, status.signedIn, let email = status.email {
            return L10n.tr("ChatGPT 账号 · \(email)", "ChatGPT account · \(email)")
        }
        return ModelProvider.openai.detail
    }
}

/// Reasoning effort and Fast mode, as far as the provider and model offer them.
private struct SpeedCard: View {
    @ObservedObject var settings: ModelSettings

    var body: some View {
        let options = settings.speedOptions
        if !options.isEmpty {
            Card(title: L10n.tr("速度", "Speed")) {
                if !options.levels.isEmpty {
                    SettingRow(title: L10n.tr("推理程度", "Reasoning"), detail: levelDetail(options), divider: options.fastTier != nil) {
                        Picker("", selection: $settings.reasoningEffort) {
                            ForEach(options.levels, id: \.self) { Text($0.label).tag($0.effort) }
                        }
                        .labelsHidden().pickerStyle(.segmented)
                        .frame(width: CGFloat(min(options.levels.count, 6)) * 70)
                    }
                }
                if let tier = options.fastTier {
                    SettingRow(title: L10n.tr("快速模式", "Fast mode"), detail: tier.detail, divider: false) {
                        Toggle("", isOn: $settings.fastMode).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func levelDetail(_ options: SpeedOptions) -> String {
        let chosen = options.levels.first { $0.effort == settings.reasoningEffort }?.detail ?? ""
        return chosen.isEmpty ? L10n.tr("越低越快；聊天回复一般用低就够了", "Lower is faster. Low is usually enough for chat replies.") : chosen
    }
}

/// OpenAI's two ways in, as the first row of its card.
private struct OpenAIMethodRow: View {
    @ObservedObject var settings: ModelSettings
    let compact: Bool

    var body: some View {
        SettingRow(title: L10n.tr("登录方式", "Sign-in method"), detail: compact ? nil : detail) {
            Picker("", selection: Binding(get: { settings.provider.usesSignIn },
                                          set: { settings.choose($0 ? .chatgpt : .openai) })) {
                Text(L10n.tr("ChatGPT 账号", "ChatGPT account")).tag(true)
                Text("API Key").tag(false)
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 200)
        }
    }

    private var detail: String {
        settings.provider.usesSignIn ? L10n.tr("用 Plus / Pro 套餐额度，不需要 API Key", "Uses your Plus / Pro plan. No API key needed.") : L10n.tr("按 OpenAI API 的用量计费", "Billed by OpenAI API usage.")
    }
}

private struct KeyFields: View {
    @ObservedObject var settings: ModelSettings
    let compact: Bool

    var body: some View {
        Card {
            if settings.usesOpenAI { OpenAIMethodRow(settings: settings, compact: compact) }
            SettingRow(title: L10n.tr("接口地址", "Endpoint"), detail: compact ? nil : L10n.tr("兼容 OpenAI 的 /v1 地址", "An OpenAI-compatible /v1 URL")) {
                TextField("https://…/v1", text: $settings.baseURL).frame(width: 260)
            }
            SettingRow(title: L10n.tr("模型", "Model"), detail: compact ? nil : L10n.tr("填服务商给的模型名", "Use the model name from your provider")) {
                TextField(settings.provider.defaultModel.isEmpty ? L10n.tr("模型名", "Model name") : settings.provider.defaultModel,
                          text: $settings.model).frame(width: 260)
            }
            SettingRow(title: "API Key", detail: keyDetail, divider: false) {
                HStack(spacing: 8) {
                    SecureField(settings.hasStoredKey ? L10n.tr("已保存，留空不变", "Saved; leave blank to keep") : "sk-…", text: $settings.apiKey)
                        .frame(width: settings.hasStoredKey ? 190 : 260)
                    if settings.hasStoredKey {
                        Button(L10n.tr("移除", "Remove")) { settings.forgetKey() }.buttonStyle(SecondaryButtonStyle())
                    }
                }
                .disabled(settings.provider.key == .none)
            }
        }
    }

    private var keyDetail: String? {
        if settings.provider.key == .optional { return compact ? nil : L10n.tr("服务要求时才填，比如本机的 Ollama 就不用", "Only if required by the service. Local Ollama needs no key.") }
        return compact ? nil : L10n.tr("存进 macOS 钥匙串，不写进配置文件", "Stored in macOS Keychain, outside the config file.")
    }
}

/// Sign-in state for the ChatGPT provider, following OpenAI's guidelines:
/// "Continue with ChatGPT" starts the flow, "Using ChatGPT plan" marks the
/// active billing, and "Manage usage" leads to the plan's usage settings.
private struct ChatGPTAccount: View {
    @ObservedObject var settings: ModelSettings
    let controller: Controller
    let compact: Bool

    private static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if settings.showPlanWelcome {
                PlanWelcome { settings.dismissPlanWelcome() }
            }
            Card {
                OpenAIMethodRow(settings: settings, compact: compact)
                if let status = settings.chatgpt, status.signedIn {
                    SettingRow(title: status.email ?? L10n.tr("已登录", "Signed in"), detail: nil) {
                        HStack(spacing: 10) {
                            StatusDot(tone: status.planUsage ? .ok : .warn, text: status.planUsage ? L10n.tr("使用 ChatGPT 套餐", "Using ChatGPT plan") : L10n.tr("未授权使用套餐", "Plan usage not authorized"))
                            Link(L10n.tr("管理用量", "Manage usage"), destination: Self.usageURL).font(.system(size: 12))
                        }
                    }
                    SettingRow(title: L10n.tr("模型", "Model"), detail: compact ? nil : L10n.tr("你的账号可以用的模型", "Models available to your account")) {
                        if settings.chatgptModels.isEmpty {
                            Button(L10n.tr("读取模型列表", "Load models")) { Task { await settings.loadChatGPTModels(controller: controller) } }
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            Picker("", selection: $settings.model) {
                                ForEach(settings.chatgptModels) { Text($0.displayName).tag($0.slug) }
                            }
                            .labelsHidden().frame(width: 220)
                        }
                    }
                    SettingRow(title: L10n.tr("退出登录", "Sign out"), detail: compact ? nil : L10n.tr("吊销这台 Mac 上的登录，并清除本机保存的令牌", "Revokes this Mac’s sign-in and removes its saved tokens."), divider: false) {
                        Button(L10n.tr("退出", "Sign out")) { Task { await settings.signOutOfChatGPT(controller: controller) } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.tr("用你的 ChatGPT Plus / Pro 套餐额度生成回复，不需要 API Key。登录后可以在 ChatGPT 设置里给这个应用设用量上限。", "Generate replies with your ChatGPT Plus / Pro plan. No API key needed. After signing in, set an app usage limit in ChatGPT settings."))
                            .font(.system(size: 12.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button(L10n.tr("使用 ChatGPT 继续", "Continue with ChatGPT")) {
                                Task { await settings.signInWithChatGPT(controller: controller) }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(settings.chatgpt?.loginPending == true)
                            if settings.chatgpt?.loginPending == true {
                                ProgressView().controlSize(.small)
                                Text(L10n.tr("在浏览器里完成登录…", "Finish signing in in your browser…")).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            if let message = settings.chatgptMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown once after the first sign-in.
private struct PlanWelcome: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("正在使用你的 ChatGPT 套餐", "You're using your ChatGPT plan")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                Text(L10n.tr("Tact 生成回复时会使用你 ChatGPT 套餐里的额度，可以在 ChatGPT 设置里管理用量。", "Tact uses your ChatGPT plan to generate replies. Manage usage in ChatGPT settings."))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L10n.tr("知道了", "Got it"), action: dismiss).buttonStyle(SecondaryButtonStyle())
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
    }
}

private struct ProviderCard: View {
    let provider: ModelProvider
    let selected: Bool
    let compact: Bool
    var detail: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: provider.symbol, size: 30, tint: selected ? Theme.accent : nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(detail ?? provider.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.controlLine)
            }
            .padding(compact ? 10 : 12)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(hovering && !selected ? Theme.hover : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(selected ? Theme.accent : hovering ? Theme.controlLine : Theme.hairline,
                                  lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: selected)
    }
}

struct TestResult: View {
    let state: ModelSettings.TestState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .passed(let message):
            Label(message, systemImage: "checkmark")
                .font(.system(size: 12)).foregroundStyle(Theme.ok).lineLimit(2)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Theme.warn).lineLimit(3)
        }
    }
}

private struct ModelPane: View {
    @ObservedObject var settings: ModelSettings
    let controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: L10n.tr("模型", "Model"), subtitle: L10n.tr("选一个生成回复的模型。云端模型会收到当前会话最近的消息；选「本机」，聊天内容不出这台 Mac。", "Choose a model for replies. Cloud models receive recent messages from the current chat. Local models keep chat content on this Mac."))
            ModelForm(settings: settings, controller: controller)
        }
    }
}

// MARK: - Style

private struct StylePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: L10n.tr("表达风格", "Writing style"), subtitle: L10n.tr("写下你说话的习惯，模型会照着起草。用「## 标题」分段，配置里可以给不同会话指定不同的段落。", "Describe how you write, and the model will follow your style. Use “## Heading” to separate sections; the config can assign a section to each chat."))
            Card {
                TextEditor(text: $model.styleText)
                    .font(Theme.mono(12.5, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(minHeight: 320)
                    .onChange(of: model.styleText) { _, _ in model.styleSaved = false }
            }
            HStack(spacing: 12) {
                Button(L10n.tr("保存", "Save")) { model.saveStyle() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.styleSaved)
                if model.styleSaved {
                    Text(L10n.tr("已保存，下一次生成就会用上", "Saved. Applies to the next suggestion.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: L10n.tr("隐私", "Privacy"), subtitle: L10n.tr("Tact 没有服务器。下面是数据会去的全部地方。", "Tact has no servers. Here is where your data goes."))
            Card(title: L10n.tr("数据去向", "Where data goes")) {
                FlowRow(symbol: "desktopcomputer", title: L10n.tr("只在这台 Mac 上", "Stays on this Mac"),
                        detail: L10n.tr("顶部栏截图和文字识别、会话列表、预取的消息（5 分钟后丢弃）、你的 API Key（钥匙串）", "Header screenshots and OCR, chat lists, prefetched messages (discarded after 5 minutes), and your API key (in Keychain)."))
                FlowRow(symbol: "arrow.up.right", title: L10n.tr("发给你选的模型服务商", "Sent to your selected model provider"),
                        detail: L10n.tr("触发时当前会话最近 \(model.historyLimit) 条消息、你在输入框里写的意图、表达风格。选「本机」模型时这些都留在这台 Mac 上", "When triggered: the current chat’s last \(model.historyLimit) messages, the intent you type, and your writing style. With a local model, all of this stays on this Mac."))
                FlowRow(symbol: "nosign", title: L10n.tr("不会发给任何其他人", "Shared with no one else"),
                        detail: L10n.tr("没有使用统计上报，没有云同步", "No analytics reporting or cloud sync."), divider: false)
            }
            Card(title: L10n.tr("日志", "Logs")) {
                SettingRow(title: L10n.tr("日志里记录聊天文字", "Include chat text in logs"), detail: L10n.tr("默认关闭：反馈日志只记长度、耗时和改动字数，统计照样能算", "Off by default. Feedback logs only record lengths, timing, and edit counts; statistics still work."), divider: false) {
                    Toggle("", isOn: $model.logPlaintext).labelsHidden().toggleStyle(.switch)
                }
            }
            .onChange(of: model.logPlaintext) { _, _ in model.applyEngineSettings() }
        }
    }
}

private struct FlowRow: View {
    let symbol: String
    let title: String
    let detail: String
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: symbol, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if divider { RowDivider(inset: 54) }
        }
    }
}

// MARK: - Stats

private struct StatsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: L10n.tr("统计", "Statistics"), subtitle: L10n.tr("只基于本机的反馈日志计算，日志里不含聊天文字。", "Calculated from local feedback logs, without chat text.")) {
                Button(L10n.tr("刷新", "Refresh")) { Task { await model.loadStats() } }.buttonStyle(SecondaryButtonStyle())
            }
            if let stats = model.stats, stats.triggers > 0 {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    StatCard(value: "\(stats.triggers)", unit: L10n.tr("次", "times"), title: L10n.tr("触发", "Trigger"),
                             detail: L10n.tr("出建议 \(stats.generated) · 不建议 \(stats.empty) · 出错 \(stats.errors)", "Suggestions \(stats.generated) · Empty \(stats.empty) · Errors \(stats.errors)"))
                    StatCard(value: percent(stats.acceptRate), unit: "", title: L10n.tr("采纳率", "Acceptance rate"),
                             detail: L10n.tr("显示 \(stats.shown) 次，接受 \(stats.accepted) 次", "Shown \(stats.shown) times; accepted \(stats.accepted)"), bar: stats.acceptRate)
                    StatCard(value: percent(stats.unchangedRate), unit: "", title: L10n.tr("原样发出", "Sent unchanged"),
                             detail: L10n.tr("接受后发出的 \(stats.sent) 条里没改一个字的比例", "Share of \(stats.sent) sent replies accepted without edits"), bar: stats.unchangedRate)
                    StatCard(value: stats.medianLatencyMS > 0 ? String(format: "%.1f", Double(stats.medianLatencyMS) / 1000) : "—",
                             unit: stats.medianLatencyMS > 0 ? L10n.tr("秒", "s") : "", title: L10n.tr("引擎耗时中位数", "Median engine latency"),
                             detail: stats.p90LatencyMS > 0 ? L10n.tr("P90 \(String(format: "%.1f", Double(stats.p90LatencyMS) / 1000)) 秒", "P90 \(String(format: "%.1f", Double(stats.p90LatencyMS) / 1000)) s") : L10n.tr("还没有数据", "No data yet"))
                }
            } else if model.statsLoading {
                ProgressView()
            } else {
                Card {
                    Text(model.stats == nil ? L10n.tr("连不上引擎，读不到统计", "Cannot connect to the engine to load statistics") : L10n.tr("还没有记录。用快捷键触发几次之后再来看。", "No records yet. Trigger a few suggestions, then check back."))
                        .font(.system(size: 13)).foregroundStyle(.secondary).padding(20)
                }
            }
        }
        .task { if model.stats == nil { await model.loadStats() } }
    }

    private func percent(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }
}

private struct StatCard: View {
    let value: String
    let unit: String
    let title: String
    let detail: String
    /// A share to draw as a meter under the figure.
    var bar: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Theme.display(28)).monospacedDigit().foregroundStyle(Theme.ink)
                Text(unit).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            // Cards without a meter keep its space so a row's cards line up.
            Group {
                if let bar { Meter(value: bar) } else { Color.clear }
            }
            .frame(height: 6)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A share drawn as a row of small squares, filled in the accent up to `value`.
private struct Meter: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            let count = 40
            let gap: CGFloat = 2
            let width = (geo.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    Rectangle()
                        .fill(Double(index) < value * Double(count) ? Theme.accent : Theme.pill)
                        .frame(width: width)
                }
            }
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 18) {
                AppIconImage().frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tact").font(Theme.display(22)).foregroundStyle(Theme.ink)
                    Text(L10n.tr("版本 \(version)", "Version \(version)")).font(Theme.mono(11)).foregroundStyle(.secondary)
                    Text(L10n.tr("不知道怎么回？按快捷键，回复就在输入框里。", "Unsure what to say? Press the shortcut for a reply in your chat input.")).font(.system(size: 13))
                }
            }
            Card(title: L10n.tr("文件位置", "File locations")) {
                SettingRow(title: L10n.tr("配置", "Configuration"), detail: AppConfig.configPath) {
                    Button(L10n.tr("打开文件夹", "Open folder")) { model.openConfigFolder() }.buttonStyle(SecondaryButtonStyle())
                }
                SettingRow(title: L10n.tr("日志", "Logs"), detail: L10n.tr("~/.tact/app.log、engine.log、feedback.jsonl", "~/.tact/app.log, engine.log, feedback.jsonl"), divider: false) {
                    EmptyView()
                }
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L10n.tr("开发版", "Development build")
    }
}
