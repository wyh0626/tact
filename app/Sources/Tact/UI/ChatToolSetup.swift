import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Instructions supplied by a plugin author.
struct PluginSetup: Codable {
    let summary: String?
    let requirements: [String]?
    let steps: [String]?
    let helpURL: String?
    var commands: [PluginSetupCommand]? = nil
    enum CodingKeys: String, CodingKey { case summary, requirements, steps, helpURL = "help_url", commands }

    var safeHelpURL: URL? {
        guard let helpURL, let url = URL(string: helpURL), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// One preparation command, such as installing a CLI or signing in to it.
/// It runs only when the user asks, in a Terminal window they can watch.
struct PluginSetupCommand: Codable {
    let title: String
    let command: String
    let detail: String?
    let inputPlaceholder: String?
    enum CodingKeys: String, CodingKey { case title, command, detail, inputPlaceholder = "input_placeholder" }

    var requiresInput: Bool { command.contains("${input}") }

    /// The command to run. `${plugin_dir}` is the installed plugin's folder,
    /// as in the manifest's entrypoint, so a plugin can run its own tools.
    func resolvedCommand(input: String, pluginDirectory: String? = nil) -> String? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, command.count <= 8192,
              command.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        var resolved = command
        if resolved.contains("${plugin_dir}") {
            guard let pluginDirectory, !pluginDirectory.isEmpty else { return nil }
            resolved = resolved.replacingOccurrences(of: "${plugin_dir}", with: shellQuoted(pluginDirectory))
        }
        guard requiresInput else { return resolved }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 512, value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return resolved.replacingOccurrences(of: "${input}", with: shellQuoted(value))
    }
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Runs a setup command in a new Terminal window. The window shows the
/// command before running it, and the script deletes itself on start.
enum TerminalRunner {
    static func script(for command: String) -> String {
        """
        #!/bin/zsh -l
        rm -f -- "$0"
        print -r -- \(shellQuoted("$ " + command))
        \(command)
        print
        print -r -- '做完后回到 Tact，点「检测并启用」。'

        """
    }

    static func run(_ command: String) throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw PlatformError.invalid("找不到「终端」应用")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tact-setup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        try script(for: command).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// What a developer needs to build a plugin, in one message the user can
/// forward. Users never have to read it themselves.
enum PluginBrief {
    static let text = """
    想请你帮忙把一个聊天工具接入 Tact

    Tact 是 macOS 上的开源菜单栏应用：在聊天窗口按快捷键，它读取当前会话最近的消息，用我自己选的模型起草回复，以灰字显示在输入框里；接受后只填入草稿，由我自己发送。没有服务器，一切在本机运行。

    接入方式是一个插件：包含 manifest.json 和实现脚本的文件夹。我在 Tact 里拖入这个文件夹或它的 .zip 就能导入。

    插件需要做到：
    1. 以我本人的身份读取会话列表和最近消息（官方接口、SDK 或命令行工具都可以）。只有机器人发消息的接口不够。
    2. 命令行协议 command-v1：`chats` 输出会话列表，`history <chat_id> <limit>` 输出最近消息，stdout 只输出一份 JSON；不支持的命令退出码为 3。
    3. 在 manifest 的 setup 里写清楚安装和登录步骤。需要终端命令的放进 setup.commands，我可以在 Tact 里一键在终端运行。
    4. 插件包里不要放真实账号、聊天记录或密钥；没实现的能力在 capabilities 里写 false。

    chats 示例：{"chats":[{"id":"chat-1","title":"测试会话","type":"private"}]}
    history 示例：{"messages":[{"id":"m-1","sender":"对方","from_me":false,"time":"2026-01-01T00:00:00Z","text":"你好"}]}

    manifest.json 示例：
    {
      "protocol_version": 1, "id": "example.my-im", "name": "我的 IM", "version": "1.0.0",
      "transport": "command-v1", "entrypoint": ["/usr/bin/python3", "${plugin_dir}/adapter.py"],
      "capabilities": {"conversations.list": true, "messages.read": true, "composer.read": true, "composer.apply": true, "overlay.inline": true, "events.subscribe": false},
      "desktop": {
        "strategy": "ax-ocr-v1", "bundle_ids": ["com.example.myim"],
        "header": {"top_offset": 28, "height": 64, "left_padding": 0},
        "overlay": {"font_size": 13, "offset_x": 0, "offset_y": 0}, "send_shortcut": "return"
      },
      "setup": {
        "summary": "需要先安装我的 IM 的命令行工具并登录。",
        "requirements": ["已安装并登录我的 IM 桌面客户端"],
        "commands": [{"title": "登录", "command": "myim login ${input}", "input_placeholder": "你的账号邮箱"}]
      }
    }

    完整规范见 Tact 项目的 docs/ADAPTER.md，可以直接复制 plugins/template/ 起步。
    """
}

@MainActor
final class AddChatToolModel: ObservableObject, Identifiable {
    let id = UUID()
    let settings: PlatformSettings
    @Published var note: String?

    init(settings: PlatformSettings) { self.settings = settings }

    /// Imports a folder or .zip. Returns whether the plugin was added.
    func importPackage(from source: URL) async -> Bool {
        settings.problem = nil
        note = nil
        return await settings.importPlugin(from: source)
    }

    func copyBrief() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(PluginBrief.text, forType: .string)
        note = "已复制，发给这个 IM 的开发者或公司的技术同事"
    }

    func openDeveloperKit() {
        if let resources = Bundle.main.resourceURL {
            let kit = resources.appendingPathComponent("PluginSDK", isDirectory: true)
            if FileManager.default.fileExists(atPath: kit.path) { NSWorkspace.shared.open(kit); return }
        }
        let template = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugins/template", isDirectory: true)
        NSWorkspace.shared.open(template)
    }
}

/// The add sheet: drop a plugin in, see what's added and what's coming,
/// and, without a plugin, a message to hand to whoever can write one.
struct AddChatToolSheet: View {
    @ObservedObject var model: AddChatToolModel
    @ObservedObject private var settings: PlatformSettings
    @Environment(\.dismiss) private var dismiss
    @State private var targeted = false
    @State private var choosing = false

    init(model: AddChatToolModel) { self.model = model; settings = model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "添加聊天工具")
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(QuietButtonStyle()).disabled(settings.busy)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        dropZone
                        Text("导入只检查文件，不会运行插件；打开开关时才会先检测连接。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }
                    if let problem = settings.problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !settings.entries.isEmpty {
                        section("已添加") {
                            ForEach(settings.entries) { entry in
                                tile(name: entry.name, detail: entry.version.isEmpty ? "插件" : "v\(entry.version)", added: true)
                            }
                        }
                    }
                    section("计划支持 · 有插件后即可导入") {
                        ForEach(PlatformSettings.planned) { platform in
                            tile(name: platform.name, detail: "计划中", added: false)
                        }
                    }
                    developerBrief
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
        }
        .frame(width: 600, height: 600)
        .background(Theme.canvas)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .zip]) { result in
            if case .success(let url) = result { add(url) }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            if settings.busy {
                ProgressView().controlSize(.small)
                Text("正在导入…").font(.system(size: 12.5)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "shippingbox").font(.system(size: 22)).foregroundStyle(targeted ? Theme.accent : Color.secondary)
                Text("把插件拖到这里").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                Text("IM 的开发者或服务商给你的文件夹，或它的 .zip").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("选择插件…") { choosing = true }.buttonStyle(SecondaryButtonStyle()).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .fill(targeted ? Theme.accentSoft : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(targeted ? Theme.accent : Theme.controlLine, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .animation(Motion.quick, value: targeted)
        .animation(Motion.quick, value: settings.busy)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !settings.busy else { return false }
            add(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private var developerBrief: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "还没有插件").padding(.horizontal, 4)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("请 IM 的开发者做一个").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(model.note ?? "插件是一个带 manifest.json 的小文件夹。复制开发说明发给对方，他们照着模板就能写。")
                        .font(.system(size: 11.5)).foregroundStyle(model.note == nil ? Color.secondary : Theme.ok)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("打开模板") { model.openDeveloperKit() }.buttonStyle(QuietButtonStyle())
                Button("复制开发说明") { model.copyBrief() }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8, content: content)
        }
    }

    /// Added and planned tools are shown, not chosen: both sit back a step.
    private func tile(name: String, detail: String, added: Bool) -> some View {
        HStack(spacing: 10) {
            Monogram(name: name, size: 26, muted: !added)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if added { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ok) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
        .opacity(added ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    private func add(_ url: URL) {
        Task {
            if await model.importPackage(from: url) { dismiss() }
        }
    }
}

/// A plugin's own setup: what it needs, then its commands in order, each
/// runnable in Terminal or copyable.
struct PluginPreparation: View {
    let setup: PluginSetup?
    var pluginDirectory: String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = setup?.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let requirements = setup?.requirements ?? []
            if !requirements.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(requirements.enumerated()), id: \.offset) { _, text in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(Color.secondary.opacity(0.6)).frame(width: 3.5, height: 3.5)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1.5 }
                            Text(text).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            let commands = setup?.commands ?? []
            let steps = setup?.steps ?? []
            if !commands.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                        PluginSetupCommandView(number: index + 1, command: command, pluginDirectory: pluginDirectory,
                                               problem: $problem)
                    }
                }
            } else if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            StepNumber(number: index + 1)
                            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else if setup?.summary?.isEmpty ?? true, requirements.isEmpty {
                Text("先打开并登录这个聊天工具。插件需要额外组件或授权时，按提供方的说明完成。")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            if let url = setup?.safeHelpURL {
                Link(destination: url) {
                    Label("提供方的安装帮助", systemImage: "arrow.up.right").font(.system(size: 12))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StepNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)").font(Theme.mono(10.5)).foregroundStyle(.secondary)
            .frame(width: 18, height: 18).background(Circle().fill(Theme.pill))
    }
}

private struct PluginSetupCommandView: View {
    let number: Int
    let command: PluginSetupCommand
    let pluginDirectory: String?
    @Binding var problem: String?
    @State private var input = ""
    @State private var copied = false

    var body: some View {
        let resolved = command.resolvedCommand(input: input, pluginDirectory: pluginDirectory)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StepNumber(number: number)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(command.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Button(copied ? "已复制" : "复制") {
                        guard let resolved else { return }
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(resolved, forType: .string)
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(resolved == nil)
                    Button("在终端中运行") {
                        guard let resolved else { return }
                        do { try TerminalRunner.run(resolved); problem = nil } catch { problem = error.localizedDescription }
                    }
                    .buttonStyle(SecondaryButtonStyle()).disabled(resolved == nil)
                }
                if let detail = command.detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if command.requiresInput {
                    TextField(command.inputPlaceholder ?? "填写所需信息", text: $input)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        .onChange(of: input) { _, _ in copied = false }
                }
                Text(resolved ?? command.command.replacingOccurrences(of: "${input}", with: "‹\(command.inputPlaceholder ?? "填写")›"))
                    .font(Theme.mono(11, weight: .regular)).foregroundStyle(resolved == nil ? Color.secondary : Theme.ink)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.pill))
            }
        }
    }
}
