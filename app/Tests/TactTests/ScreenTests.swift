import AppKit
import SwiftUI
import Testing
@testable import Tact

/// Renders every settings pane and onboarding step against a throwaway
/// config, keychain entry and engine socket, so nothing touches the user's
/// real setup. The PNGs are for reviewing the design; the assertions make
/// sure each screen draws at all.
@MainActor
@Suite(.serialized)
struct ScreenTests {
    private let socket: String

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tact-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("config.json").path
        let style = dir.appendingPathComponent("style.md").path
        try "- 简短直接，不用感叹号\n\n## 工作聊天\n- 先说结论\n".write(toFile: style, atomically: true, encoding: .utf8)
        try ConfigFile.initial(styleFile: style,
                               feedbackFile: dir.appendingPathComponent("feedback.jsonl").path)
            .write(to: config)
        setenv("TACT_CONFIG", config, 1)
        Keychain.service = "io.github.wyh0626.tact.tests"
        socket = dir.appendingPathComponent("none.sock").path
    }

    private func makeController() -> Controller {
        var config = AppConfig.load().0
        config.socketPath = socket
        return Controller(config: config)
    }

    @Test func switchingBackKeepsThePageAndScrollPosition() throws {
        let model = SettingsModel(controller: makeController())
        let container = SettingsPaneContainer(frame: NSRect(x: 0, y: 0, width: 667, height: 620))
        let window = NSWindow(contentRect: container.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.show(.general, model: model)
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let general = try #require(container.subviews.first)
        let scroll = try #require(findScrollView(in: general))
        // Scroll somewhere the page can actually reach, whatever its height.
        let reachable = (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height
        #expect(reachable > 20)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(100, reachable - 10)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let position = scroll.contentView.bounds.origin
        #expect(position.y > 0)

        model.pane = .style
        container.show(.style, model: model)
        let style = try #require(container.subviews.first)
        model.pane = .general
        container.show(.general, model: model)
        container.layoutSubtreeIfNeeded()
        #expect(container.subviews.count == 1)
        #expect(container.subviews.first === general)
        #expect(scroll.contentView.bounds.origin == position)
        #expect(style.superview == nil)
        model.pane = .style
        container.show(.style, model: model)
        #expect(container.subviews.first === style)
    }

    @Test func statusRefreshLetsTheMainActorRunWhileTheEngineWaits() async throws {
        let server = try WaitingPingServer()
        var config = AppConfig.load().0
        config.socketPath = server.path
        let model = SettingsModel(controller: Controller(config: config))
        let refresh = model.refreshStatus()
        // The fake engine cannot reply until this main-actor task runs.
        // A synchronous ping on the main actor would time out first.
        Task { @MainActor in
            await Task.yield()
            server.releaseResponse()
        }
        await refresh.value
        #expect(model.engineConnected)
        #expect(await server.finished.value)
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    /// The check started when the model was made answers after the hold
    /// and must not undo it.
    @Test func aSetUpStatusHoldsAgainstLiveChecks() async throws {
        let model = SettingsModel(controller: makeController())
        model.showAsSetUp()
        await model.refreshStatus().value
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(model.engineConnected && model.statusChecked)
        #expect(Permission.allCases.allSatisfy { model.permissions[$0] == true })
    }

    @Test func settingsPanes() {
        let model = SettingsModel(controller: makeController())
        model.stats = StatsData([
            "triggers": 42, "generated": 36, "empty": 4, "errors": 2, "shown": 36, "accepted": 27,
            "sent": 25, "sent_unchanged": 19, "median_latency_ms": 1180, "p90_latency_ms": 2400,
        ])
        for pane in SettingsPane.allCases {
            model.pane = pane
            for dark in [false, true] {
                let name = "settings-\(pane.rawValue)-\(dark ? "dark" : "light")"
                #expect(Snapshot.render(SettingsView(model: model), name: name, size: CGSize(width: 880, height: 620), dark: dark) != nil)
            }
        }
    }

    /// Capture the whole plugin page instead of the settings window's fixed
    /// viewport, including an opened row below the list.
    @Test func chatToolsList() throws {
        var file = try ConfigFile.load(from: AppConfig.configPath)
        file.set("platforms", [])
        try file.write(to: AppConfig.configPath)
        let empty = SettingsModel(controller: makeController())
        #expect(empty.platformSettings.entries.isEmpty)
        for dark in [false, true] {
            #expect(Snapshot.render(page(empty), name: "chat-tools-empty-\(dark ? "dark" : "light")",
                                    size: CGSize(width: 640, height: 520), dark: dark) != nil)
        }

        file.set("platforms", [["id": "imported-example", "manifest": ExamplePlugin.manifest,
                                "enabled": false, "origin": "imported"]])
        try file.write(to: AppConfig.configPath)
        let model = SettingsModel(controller: makeController())
        model.pane = .chat
        #expect(model.platformSettings.selected?.name == ExamplePlugin.name)
        for dark in [false, true] {
            #expect(Snapshot.render(page(model), name: "chat-tools-plugin-\(dark ? "dark" : "light")",
                                    size: CGSize(width: 640, height: 1180), dark: dark) != nil)
        }
    }

    @Test func weChatCard() throws {
        var file = try ConfigFile.load(from: AppConfig.configPath)
        file.set("platforms", [])
        file.set("app.wechat", true)
        try file.write(to: AppConfig.configPath)
        let model = SettingsModel(controller: makeController())
        #expect(model.wechat)
        for dark in [false, true] {
            #expect(Snapshot.render(page(model), name: "chat-tools-wechat-\(dark ? "dark" : "light")",
                                    size: CGSize(width: 640, height: 640), dark: dark) != nil)
        }
        file.set("app.wechat", nil)
        try file.write(to: AppConfig.configPath)
    }

    @Test func addChatToolSheet() throws {
        var file = try ConfigFile.load(from: AppConfig.configPath)
        file.set("platforms", [["id": "imported-example", "manifest": ExamplePlugin.manifest,
                                "enabled": false, "origin": "imported"]])
        try file.write(to: AppConfig.configPath)
        let model = SettingsModel(controller: makeController())
        let sheet = AddChatToolModel(settings: model.platformSettings)
        for dark in [false, true] {
            #expect(Snapshot.render(AddChatToolSheet(model: sheet), name: "chat-tool-add-\(dark ? "dark" : "light")",
                                    size: CGSize(width: 600, height: 560), dark: dark) != nil)
        }
    }

    private func page(_ model: SettingsModel) -> some View {
        ChatToolsPane(model: model).padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.canvas)
    }

    @Test func chatgptSignInStates() {
        let model = SettingsModel(controller: makeController())
        model.pane = .model
        let settings = model.modelSettings
        settings.choose(.chatgpt)
        settings.chatgptMessage = nil
        settings.chatgpt = ChatGPTStatus(signedIn: false, email: nil, planUsage: false, loginPending: false, loginError: nil)
        #expect(Snapshot.render(SettingsView(model: model), name: "settings-chatgpt-signed-out",
                                size: CGSize(width: 880, height: 760)) != nil)
        settings.chatgpt = ChatGPTStatus(signedIn: true, email: "me@example.com", planUsage: true, loginPending: false, loginError: nil)
        let levels: [ChatGPTModel.Level] = ["low", "medium", "high", "xhigh"].map { .init(effort: $0, description: "") }
        settings.chatgptModels = [
            ChatGPTModel(slug: "gpt-fast", displayName: "GPT Fast", reasoningLevels: levels, defaultReasoning: "low",
                         speedTiers: [.init(id: "priority", name: "Fast", description: "2x speed, increased usage")]),
            ChatGPTModel(slug: "gpt-deep", displayName: "GPT Deep", reasoningLevels: levels, defaultReasoning: "medium"),
        ]
        settings.model = "gpt-fast"
        settings.reasoningEffort = "low"
        settings.showPlanWelcome = true
        #expect(Snapshot.render(SettingsView(model: model), name: "settings-chatgpt-signed-in",
                                size: CGSize(width: 880, height: 1000), dark: true) != nil)
    }

    /// The whole model form at full height, for the parts below the fold.
    @Test func speedCards() {
        let controller = makeController()
        let settings = ModelSettings(file: ConfigFile(root: [:]))
        let levels: [ChatGPTModel.Level] = ["low", "medium", "high", "xhigh"].map { .init(effort: $0, description: "") }
        settings.chatgptModels = [ChatGPTModel(slug: "gpt-fast", displayName: "GPT Fast", reasoningLevels: levels,
                                               defaultReasoning: "low",
                                               speedTiers: [.init(id: "priority", name: "Fast", description: "2x speed, increased usage")])]
        settings.choose(.chatgpt)
        settings.chatgpt = ChatGPTStatus(signedIn: true, email: "me@example.com", planUsage: true, loginPending: false, loginError: nil)
        settings.model = "gpt-fast"
        settings.reasoningEffort = "low"
        settings.fastMode = true
        let chatgpt = ModelForm(settings: settings, controller: controller).padding(28).background(Theme.canvas)
        #expect(Snapshot.render(chatgpt, name: "model-form-chatgpt", size: CGSize(width: 640, height: 900)) != nil)

        let deepseek = ModelSettings(file: ConfigFile(root: [:]))
        deepseek.choose(.deepseek)
        let form = ModelForm(settings: deepseek, controller: controller).padding(28).background(Theme.canvas)
        #expect(Snapshot.render(form, name: "model-form-deepseek", size: CGSize(width: 640, height: 820), dark: true) != nil)

        let models = FileManager.default.temporaryDirectory.appendingPathComponent("tact-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: models) }
        let store = LocalModelStore(directory: models)
        let small = LocalModel.catalog[0]
        try? FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: store.url(for: small).path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: store.url(for: small)) {
            try? handle.truncate(atOffset: UInt64(small.bytes))
            try? handle.close()
        }
        store.refresh()
        let local = ModelSettings(file: ConfigFile(root: [:]), localStore: store)
        local.choose(.local)
        local.useLocalModel(small)
        let localForm = ModelForm(settings: local, controller: controller).padding(28).background(Theme.canvas)
        #expect(Snapshot.render(localForm, name: "model-form-local", size: CGSize(width: 640, height: 720)) != nil)

        let apiKey = ModelSettings(file: ConfigFile(root: [:]))
        apiKey.choose(.openai)
        let keyForm = ModelForm(settings: apiKey, controller: controller).padding(28).background(Theme.canvas)
        #expect(Snapshot.render(keyForm, name: "model-form-openai-key", size: CGSize(width: 640, height: 820)) != nil)
    }

    @Test func quickPanel() throws {
        var file = try ConfigFile.load(from: AppConfig.configPath)
        file.set("platforms", [["id": "imported-example", "manifest": ExamplePlugin.manifest,
                                "enabled": false, "origin": "imported"]])
        try file.write(to: AppConfig.configPath)
        let model = SettingsModel(controller: makeController())
        let speed = ModelSettings(file: ConfigFile(root: ["model": ["provider": "chatgpt", "model": "gpt-sol"]]))
        let levels: [ChatGPTModel.Level] = ["low", "medium", "high", "xhigh"].map { .init(effort: $0, description: "") }
        speed.chatgptModels = [ChatGPTModel(slug: "gpt-sol", displayName: "GPT-6.1-Sol", reasoningLevels: levels, defaultReasoning: "low",
                                            speedTiers: [.init(id: "priority", name: "Fast", description: "2x speed, increased usage")])]
        speed.reconcileSpeed()
        let actions = QuickPanelActions(openSettings: { _ in }, openOnboarding: {}, quit: {}, speedSaved: { _ in })
        for dark in [false, true] {
            let panel = QuickPanelView(settings: model, platforms: model.platformSettings, speed: speed,
                                       status: QuickPanelStatus(hotkey: "双击 ⌃", problem: nil), actions: actions)
                .frame(width: QuickPanelController.width).background(Theme.canvas)
            #expect(Snapshot.render(panel, name: "quick-panel-\(dark ? "dark" : "light")", size: CGSize(width: 320, height: 430), dark: dark) != nil)
        }
        file.set("app.wechat", true)
        try file.write(to: AppConfig.configPath)
        let withWeChat = SettingsModel(controller: makeController())
        #expect(withWeChat.wechat)
        let panel = QuickPanelView(settings: withWeChat, platforms: withWeChat.platformSettings, speed: speed,
                                   status: QuickPanelStatus(hotkey: "双击 ⌃", problem: nil), actions: actions)
            .frame(width: QuickPanelController.width).background(Theme.canvas)
        #expect(Snapshot.render(panel, name: "quick-panel-wechat", size: CGSize(width: 320, height: 480)) != nil)
        file.set("app.wechat", nil)
        try file.write(to: AppConfig.configPath)
    }

    /// A version a background check found, at the top of the panel.
    @Test func quickPanelWithAnUpdateWaiting() {
        let model = SettingsModel(controller: makeController())
        model.showAsSetUp()
        let updates = Updates()
        updates.noticed("0.1.3")
        let actions = QuickPanelActions(openSettings: { _ in }, openOnboarding: {}, quit: {}, speedSaved: { _ in })
        for dark in [false, true] {
            let panel = QuickPanelView(settings: model, platforms: model.platformSettings, speed: model.modelSettings,
                                       status: QuickPanelStatus(hotkey: "双击 ⌃", problem: nil), actions: actions, updates: updates)
                .frame(width: QuickPanelController.width).background(Theme.canvas)
            #expect(Snapshot.render(panel, name: "quick-panel-update-\(dark ? "dark" : "light")",
                                    size: CGSize(width: 320, height: 480), dark: dark) != nil)
        }
    }

    @Test func onboardingSteps() {
        let model = OnboardingModel(controller: makeController())
        for step in OnboardingStep.allCases {
            model.step = step
            for dark in [false, true] {
                let name = "onboarding-\(step.rawValue)-\(step)-\(dark ? "dark" : "light")"
                #expect(Snapshot.render(OnboardingView(model: model), name: name, size: CGSize(width: 860, height: 620), dark: dark) != nil)
            }
        }
    }
}

// English layouts share the serialized screen suite and its throwaway config.
extension ScreenTests {
    @Test func rendersEnglishSettingsOnboardingAndPanel() {
        L10n.$overrideLanguage.withValue(.english) {
            let controller = makeController()
            let settings = SettingsModel(controller: controller)
            settings.showAsSetUp()
            for pane in [SettingsPane.general, .model, .chat, .privacy, .stats, .about] {
                settings.pane = pane
                #expect(Snapshot.render(SettingsView(model: settings), name: "english-settings-\(pane.rawValue)",
                                        size: CGSize(width: 880, height: 620)) != nil)
            }
            let actions = QuickPanelActions(openSettings: { _ in }, openOnboarding: {}, quit: {}, speedSaved: { _ in })
            let panel = QuickPanelView(settings: settings, platforms: settings.platformSettings, speed: settings.modelSettings,
                                       status: QuickPanelStatus(hotkey: controller.hotKeyDisplay, problem: nil), actions: actions)
                .frame(width: QuickPanelController.width).background(Theme.canvas)
            for dark in [false, true] {
                #expect(Snapshot.render(panel, name: "english-quick-panel-\(dark ? "dark" : "light")",
                                        size: CGSize(width: 320, height: 480), dark: dark) != nil)
            }
            let onboarding = OnboardingModel(controller: controller)
            let previousStep = UserDefaults.standard.object(forKey: OnboardingModel.stepKey)
            defer {
                UserDefaults.standard.set(previousStep, forKey: OnboardingModel.stepKey)
                onboarding.stopWatchingPermissions()
            }
            for step in [OnboardingStep.welcome, .practice] {
                onboarding.step = step
                #expect(Snapshot.render(OnboardingView(model: onboarding), name: "english-onboarding-\(step.rawValue)",
                                        size: CGSize(width: 860, height: 620)) != nil)
            }
        }
    }
}
