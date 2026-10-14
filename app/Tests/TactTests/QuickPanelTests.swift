import AppKit
import SwiftUI
import Testing
@testable import Tact

@MainActor
struct QuickPanelTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 320, height: 400)

    @Test func panelHangsCentredUnderTheIcon() {
        let icon = CGRect(x: 1000, y: 875, width: 24, height: 24)
        let frame = QuickPanelController.frame(size: size, below: icon, within: screen)
        #expect(frame.midX == icon.midX)
        #expect(frame.maxY == icon.minY - 6)
        #expect(frame.size == size)
    }

    @Test func panelStaysInsideTheScreenNearItsEdges() {
        let right = QuickPanelController.frame(size: size, below: CGRect(x: 1420, y: 875, width: 20, height: 24), within: screen)
        #expect(right.maxX == screen.maxX - 8)
        let left = QuickPanelController.frame(size: size, below: CGRect(x: 2, y: 875, width: 20, height: 24), within: screen)
        #expect(left.minX == screen.minX + 8)
        // A second display to the right: coordinates beyond the first.
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let there = QuickPanelController.frame(size: size, below: CGRect(x: 1450, y: 1055, width: 24, height: 24), within: second)
        #expect(there.minX == second.minX + 8)
    }

    @Test func panelIsNeverTallerThanTheRoomBelowTheMenuBar() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let frame = QuickPanelController.frame(size: CGSize(width: 320, height: 900),
                                               below: CGRect(x: 700, y: 300, width: 24, height: 24), within: short)
        #expect(frame.minY >= short.minY + 8)
        #expect(frame.maxY == CGFloat(294))
    }

    /// Regression: content taller than the panel was centred by the host,
    /// pushing the panel's header out of its top edge.
    @Test func tallContentStaysPinnedToTheTop() {
        var top: CGFloat = -1
        var reported: CGFloat = 0
        let content = VStack(spacing: 0) {
            Color.red.frame(height: 20)
                .background(GeometryReader { Color.clear.preference(key: TopEdge.self, value: $0.frame(in: .global).minY) })
            Color.blue.frame(height: 400)
        }
        .onPreferenceChange(TopEdge.self) { top = $0 }
        let host = NSHostingView(rootView: QuickPanelController.pinnedToTop(content) { reported = $0 })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(top == 0, "the top of the content sits at the top of the panel")
        #expect(reported == 420)
        #expect(host.frame.height == 100, "the panel sizes the host, never the content")
    }

    @Test func savingSpeedChangesOnlyTheSpeedFields() throws {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quick-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json").path
        let saved = ConfigFile(root: [
            "model": ["base_url": "https://api.deepseek.com/v1", "model": "deepseek-flash",
                      "extra_body": ["thinking": ["type": "disabled"]], "timeout_ms": 20000],
            "app": ["hotkey": "double+ctrl"],
        ])
        try saved.write(to: path)
        let speed = ModelSettings(file: try ConfigFile.load(from: path))
        // Edits elsewhere in a form must not reach the file through a speed save.
        speed.baseURL = "https://elsewhere.example.com/v1"
        speed.model = "something-else"
        speed.reasoningEffort = "high"
        try speed.writeSpeedOnly(to: path)

        let file = try ConfigFile.load(from: path)
        #expect(file.string("model.reasoning_effort") == "high")
        #expect(file.value("model.extra_body") == nil)
        #expect(file.string("model.base_url") == "https://api.deepseek.com/v1")
        #expect(file.string("model.model") == "deepseek-flash")
        #expect(file.number("model.timeout_ms") == 20000)
        #expect(file.string("app.hotkey") == "double+ctrl")
    }

    @Test func openSettingsTakeAPanelSpeedOnlyForTheSameModel() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let root: [String: Any] = ["model": ["base_url": "https://api.openai.com/v1", "model": "gpt-x"]]
        let window = ModelSettings(file: ConfigFile(root: root))
        let panel = ModelSettings(file: ConfigFile(root: root))
        panel.reasoningEffort = "high"
        panel.fastMode = true
        window.adoptSpeed(from: panel)
        #expect(window.reasoningEffort == "high" && window.fastMode)

        let elsewhere = ModelSettings(file: ConfigFile(root: root))
        elsewhere.model = "gpt-y"
        panel.reasoningEffort = "low"
        elsewhere.adoptSpeed(from: panel)
        #expect(elsewhere.reasoningEffort != "low", "a different model keeps its own choice")
    }

    @Test func modelSummaryNamesTheCardAndTheModel() {
        Keychain.service = "io.github.wyh0626.tact.tests"
        let settings = ModelSettings(file: ConfigFile(root: ["model": ["provider": "chatgpt", "model": "gpt-6.1-sol"]]))
        #expect(settings.summary == "OpenAI · gpt-6.1-sol")
        settings.chatgptModels = [ChatGPTModel(slug: "gpt-6.1-sol", displayName: "GPT-6.1-Sol")]
        #expect(settings.summary == "OpenAI · GPT-6.1-Sol")
        settings.useLocalModel(LocalModel.catalog[0])
        settings.choose(.local)
        #expect(settings.summary == L10n.tr("本机 · Qwen3 1.7B", "Local · Qwen3 1.7B"))
    }
}

private struct TopEdge: PreferenceKey {
    static let defaultValue: CGFloat = -1
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
