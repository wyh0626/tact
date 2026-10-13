import SwiftUI

struct ChatToolsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var settings: PlatformSettings
    @State private var adding: AddChatToolModel?

    init(model: SettingsModel) {
        self.model = model
        settings = model.platformSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "聊天工具", subtitle: "在这些应用的聊天窗口里按快捷键生成建议。接受后只填进输入框，由你发送。") {
                if !settings.entries.isEmpty {
                    Button { add() } label: { Label("添加", systemImage: "plus") }
                        .buttonStyle(SecondaryButtonStyle()).disabled(settings.busy)
                }
            }

            WeChatCard(model: model, settings: settings)

            ChatToolList(settings: settings, onAdd: add)

            if let problem = settings.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card(title: "上下文") {
                SettingRow(title: "读取消息条数", detail: "插件读取的最近消息条数；微信读取当前聊天区的可见文字", divider: false) {
                    Stepper("\(model.historyLimit) 条", value: $model.historyLimit, in: 5...50, step: 5)
                        .font(Theme.mono(12)).frame(width: 120)
                }
            }
            .onChange(of: model.historyLimit) { _, _ in model.applyEngineSettings() }
        }
        .sheet(item: $adding) { AddChatToolSheet(model: $0) }
    }

    private func add() {
        settings.problem = nil
        adding = AddChatToolModel(settings: settings)
    }
}

/// WeChat, built in: it has no plugin interface, so Tact reads its window.
private struct WeChatCard: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: PlatformSettings

    var body: some View {
        Card(title: "内置") {
            SettingRow(title: "微信", detail: "定位当前聊天区，在本机识别文字和位置，再交给所选 AI 理解并生成建议。"
                       + "只读取窗口内可见内容，可以先开测试模式检查识别范围。", divider: model.wechat) {
                Toggle("微信", isOn: Binding(get: { model.wechat }, set: { model.setWeChat($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if model.wechat {
                if model.permissions[.screenRecording] == false {
                    SettingRow(title: "需要屏幕录制权限", detail: "在系统设置里打开 Tact 的屏幕录制，然后重新打开 Tact") {
                        Button("打开系统设置") { Permission.screenRecording.openSystemSettings() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                SettingRow(title: "测试模式", detail: "在微信里按快捷键，只显示本机识别的画面文字，不调用 AI", divider: false) {
                    Toggle("测试模式", isOn: Binding(get: { settings.ocrTestMode }, set: { settings.setOCRTestMode($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .animation(Motion.spring, value: model.wechat)
    }
}

/// The added chat tools as one list. A row opens in place to show what the
/// plugin still needs, its connection, and its calibration; the switch
/// checks the connection before it turns a plugin on.
struct ChatToolList: View {
    @ObservedObject var settings: PlatformSettings
    let onAdd: () -> Void
    @State private var expandedID: String?
    @State private var removing: PlatformEntry?

    var body: some View {
        Card(title: "插件") {
            if settings.entries.isEmpty {
                emptyRow
            } else {
                ForEach(Array(settings.entries.enumerated()), id: \.element.id) { index, entry in
                    ChatToolRow(entry: entry, expanded: expandedID == entry.id,
                                checking: settings.checkingID == entry.id, busy: settings.busy,
                                toggleExpanded: { toggle(entry) },
                                setEnabled: { setEnabled($0, entry: entry) })
                    if expandedID == entry.id {
                        ChatToolDetail(settings: settings, entry: entry) { removing = entry }
                            .transition(.opacity)
                    }
                    if index < settings.entries.count - 1 { RowDivider(inset: 0) }
                }
            }
        }
        .animation(Motion.spring, value: settings.entries.map(\.id))
        .onAppear {
            // A plugin that isn't on yet still has setup to do: show it.
            if expandedID == nil, let pending = settings.entries.first(where: { !$0.enabled }) { open(pending.id, animated: false) }
        }
        .onChange(of: settings.entries.map(\.id)) { before, after in
            // A plugin just imported opens on its setup.
            if let added = after.first(where: { !before.contains($0) }) { open(added) }
        }
        .confirmationDialog("移除 \(removing?.name ?? "")？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("移除", role: .destructive) {
                if let removing { settings.select(removing.id); settings.removeSelected() }
                removing = nil
            }
        } message: {
            Text("Tact 不再使用它。插件文件留在配置文件夹里，可以再导入。")
        }
    }

    private var emptyRow: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "plus", size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("还没有导入插件").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                Text("导入 IM 的开发者或服务商提供的插件，就能在它的聊天窗口里生成建议。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("添加聊天工具", action: onAdd).buttonStyle(PrimaryButtonStyle()).disabled(settings.busy)
        }
        .padding(16)
    }

    private func open(_ id: String, animated: Bool = true) {
        settings.select(id)
        withAnimation(animated ? Motion.spring : nil) { expandedID = id }
    }

    private func toggle(_ entry: PlatformEntry) {
        if expandedID == entry.id {
            withAnimation(Motion.spring) { expandedID = nil }
        } else {
            open(entry.id)
        }
    }

    private func setEnabled(_ on: Bool, entry: PlatformEntry) {
        settings.problem = nil
        if on {
            open(entry.id)
            Task { await settings.checkAndEnable(id: entry.id) }
        } else {
            settings.setEnabled(false, id: entry.id)
        }
    }
}

private struct ChatToolRow: View {
    let entry: PlatformEntry
    let expanded: Bool
    let checking: Bool
    let busy: Bool
    let toggleExpanded: () -> Void
    let setEnabled: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: toggleExpanded) {
                HStack(spacing: 12) {
                    Monogram(name: entry.name, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                            if !entry.version.isEmpty {
                                Text("v\(entry.version)").font(Theme.mono(10.5, weight: .regular)).foregroundStyle(.secondary)
                            }
                        }
                        StatusDot(tone: entry.tone, text: entry.status)
                            .contentTransition(.opacity)
                            .animation(Motion.quick, value: entry.status)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel("\(entry.name)，\(entry.status)")
            .accessibilityHint(expanded ? "收起详情" : "展开详情")

            if checking { ProgressView().controlSize(.small).transition(.opacity) }
            Toggle("启用 \(entry.name)", isOn: Binding(get: { entry.enabled }, set: setEnabled))
                .labelsHidden().toggleStyle(.switch)
                .disabled(busy || !entry.supported && !entry.enabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hovering && !expanded ? Theme.hover : .clear)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: checking)
    }
}

/// An opened row: setup while the plugin is off, then the connection, what
/// it can do, calibration, and where its files are.
private struct ChatToolDetail: View {
    @ObservedObject var settings: PlatformSettings
    let entry: PlatformEntry
    let remove: () -> Void
    @State private var showsSetup = false
    @State private var showsCalibration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if entry.supported {
                if entry.enabled {
                    DisclosureGroup(isExpanded: $showsSetup) {
                        PluginPreparation(setup: settings.selectedSetup, pluginDirectory: settings.selectedPluginDirectory)
                            .padding(.top, 10)
                    } label: { sectionTitle("安装与登录") }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("准备")
                        PluginPreparation(setup: settings.selectedSetup, pluginDirectory: settings.selectedPluginDirectory)
                    }
                }
                connection
                capabilities
                DisclosureGroup(isExpanded: $showsCalibration) {
                    calibration.padding(.top, 10)
                } label: { sectionTitle("会话识别校准") }
            } else {
                Text("插件文件有问题，没法使用。可以移除后重新导入提供方的新版本。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(.leading, 60).padding(.trailing, 16).padding(.top, 4).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sunken)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("连接")
            if !entry.enabled, let command = settings.selectedCommand {
                Text("检测会在本机运行这个插件（\(command)），读取 \(entry.name) 的会话列表，不会发送任何消息。只启用你信任的人提供的插件。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if entry.enabled {
                    Button(settings.checkingID == entry.id ? "检测中…" : "重新检测") {
                        Task { await settings.testSelected() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(settings.checkingID == entry.id ? "检测中…" : "检测并启用") {
                        Task { await settings.checkAndEnable(id: entry.id) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if entry.checked {
                    StatusDot(tone: entry.tone, text: entry.status, lineLimit: 4)
                        .contentTransition(.opacity).transition(.opacity)
                }
            }
            .animation(Motion.quick, value: entry.status)
            .disabled(settings.busy)
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !entry.supportsSuggestions {
                Text("这个插件只能读取消息，还不能在输入框里给建议。")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            Text("能做：" + entry.capabilityLabels.joined(separator: " · "))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("建议出现在错误的会话里时才需要调整。打开测试模式后按快捷键，只识别当前会话，不生成回复。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                SettingRow(title: "应用标识", detail: "用来认出前台的聊天应用，由插件提供") {
                    TextField("Bundle ID", text: $settings.targetBundleID)
                        .font(Theme.mono(11.5, weight: .regular)).frame(width: 190)
                }
                SettingRow(title: "顶部栏位置", detail: "会话标题区距窗口顶部的距离和高度，单位是点") {
                    HStack(spacing: 8) {
                        Stepper("\(Int(settings.headerTopOffset))", value: $settings.headerTopOffset, in: 0...200, step: 2)
                            .frame(width: 76).help("距窗口顶部")
                        Stepper("\(Int(settings.headerHeight))", value: $settings.headerHeight, in: 20...160, step: 4)
                            .frame(width: 76).help("截取高度")
                    }
                    .font(Theme.mono(12))
                }
                SettingRow(title: "测试模式", detail: "触发时只识别会话") {
                    Toggle("测试模式", isOn: Binding(get: { settings.ocrTestMode }, set: { settings.setOCRTestMode($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingRow(title: "保存顶部栏截图", detail: "下一次触发时存到 ~/.tact/debug/", divider: false) {
                    Button("保存下一次") { settings.saveNextHeader() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Button("保存校准") { settings.saveSelectedDesktop() }
                .buttonStyle(SecondaryButtonStyle()).disabled(settings.busy)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let identity = settings.selectedIdentity {
                Text(identity).font(Theme.mono(10.5, weight: .regular)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("打开插件文件夹") { settings.openPluginFolder() }.buttonStyle(QuietButtonStyle())
            Button("移除", action: remove).buttonStyle(QuietButtonStyle(tint: Theme.danger)).disabled(settings.busy)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
    }
}
