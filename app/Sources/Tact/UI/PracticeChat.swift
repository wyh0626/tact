import AppKit

/// One line of the practice chat.
struct PracticeMessage: Identifiable, Equatable {
    let id: UUID
    let fromMe: Bool
    let text: String

    init(id: UUID = UUID(), fromMe: Bool, text: String) {
        self.id = id
        self.fromMe = fromMe
        self.text = text
    }
}

/// What the practice asks people to try, in order.
enum PracticeTask: Int, CaseIterable {
    case suggest, accept, rewrite, replace, send

    func title(hotkey: String) -> String {
        switch self {
        case .suggest: return L10n.tr("输入框空着时按 \(hotkey)，看到灰色的回复", "With an empty input box, press \(hotkey) to see a suggestion")
        case .accept: return L10n.tr("按 Tab 把它填进输入框", "Press Tab to insert it")
        case .rewrite: return L10n.tr("清空，打「\(PracticeChat.draftExample)」，再按 \(hotkey)", "Clear the input, type “\(PracticeChat.draftExample)”, then press \(hotkey)")
        case .replace: return L10n.tr("按 Tab 换成改写好的话", "Press Tab to use the rewritten reply")
        case .send: return L10n.tr("按回车发出去（练习不会真的发送）", "Press Return to send (only in this practice)")
        }
    }
}

/// The practice chat in the first-run guide: a friend asking about dinner,
/// answered with the real hotkey, model and overlay, in Tact's own window.
/// Nothing leaves it and nothing goes into the stats.
@MainActor
final class PracticeChat: ObservableObject, ScreenSession {
    nonisolated static var friend: String { L10n.tr("小林", "Lin") }
    nonisolated static var draftExample: String { L10n.tr("拒绝", "decline") }
    nonisolated private static let openingIDs = (0..<5).map { _ in UUID() }
    nonisolated static var opening: [PracticeMessage] { [
        PracticeMessage(id: openingIDs[0], fromMe: false, text: L10n.tr("在吗", "Hey, are you around?")),
        PracticeMessage(id: openingIDs[1], fromMe: false, text: L10n.tr("下周六晚上有空不？", "Are you free next Saturday evening?")),
        PracticeMessage(id: openingIDs[2], fromMe: true, text: L10n.tr("应该有，咋了", "I think so. What’s up?")),
        PracticeMessage(id: openingIDs[3], fromMe: false, text: L10n.tr("公司附近新开了家潮汕牛肉火锅，评价超好", "There’s a new beef hot pot place near the office. The reviews are great.")),
        PracticeMessage(id: openingIDs[4], fromMe: false, text: L10n.tr("六点半，我叫上阿杰一起？", "How about 6:30? Shall I ask Jay to join us?")),
    ] }

    @Published private(set) var messages = PracticeChat.opening
    @Published var draft = ""
    @Published private(set) var done = Set<PracticeTask>()
    @Published private(set) var working = false
    /// Said under the chat when the model could not answer.
    @Published private(set) var note: String?

    let hotkey: String
    /// The input box, for placing the overlay; set by the view.
    weak var inputView: NSView?
    /// The input box's own colour, resolved for its appearance.
    var inputColor: () -> NSColor = { .textBackgroundColor }
    private let overlay: Overlay
    private let suggest: ([String: Any]) async -> [String: Any]?
    private var shown: (text: String, mode: String)?
    private var generation = 0
    private var openingTexts = PracticeChat.opening.map(\.text)

    init(hotkey: String, overlay: Overlay, suggest: @escaping ([String: Any]) async -> [String: Any]?) {
        self.hotkey = hotkey
        self.overlay = overlay
        self.suggest = suggest
    }

    var finished: Bool { done.count == PracticeTask.allCases.count }

    /// The input box in accessibility coordinates (top-left origin).
    var inputFrame: CGRect? {
        guard let view = inputView, let window = view.window else { return nil }
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        return CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    nonisolated static func payload(messages: [PracticeMessage], draft: String) -> [String: Any] {
        [
            "op": "suggest",
            "request_id": UUID().uuidString,
            "platform_id": "practice",
            "input": draft,
            "screen": [
                "title": friend,
                "type": "private",
                "messages": messages.map { ["sender": $0.fromMe ? "" : friend, "from_me": $0.fromMe, "text": $0.text] },
            ] as [String: Any],
        ]
    }

    /// Shown when the model cannot be reached, so the practice still shows
    /// what a suggestion looks like.
    nonisolated static func example(for mode: String) -> String {
        mode == "rewrite" ? L10n.tr("周六我有点事去不了😅 你们先吃，下次我请！", "I can’t make it Saturday 😅 Go ahead without me. Next time’s on me!") : L10n.tr("好啊！六点半没问题，地址发我一下～", "Sounds good! 6:30 works for me. Send me the address?")
    }

    private func mark(_ task: PracticeTask) { done.insert(task) }

    // MARK: - ScreenSession

    func trigger(_ app: NSRunningApplication) { start() }

    func start() {
        guard !working, let frame = inputFrame else { return }
        hideSuggestion()
        let draft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = draft.isEmpty ? "complete" : "rewrite"
        working = true
        note = nil
        generation += 1
        let current = generation
        overlay.showWorking(caret: nil, input: frame, fontSize: 13)
        let payload = Self.payload(messages: messages, draft: draft)
        Task {
            let raw = await suggest(payload)
            guard current == generation else { return }
            working = false
            let response = raw.map(EngineResponse.init)
            var text = response?.ok == true ? response?.suggestion : nil
            if text?.isEmpty ?? true {
                note = raw == nil ? L10n.tr("连不上模型，先用示例演示；之后可以在设置里检查模型。", "Couldn’t reach the model, so here’s an example. You can check your model in Settings later.")
                    : L10n.tr("模型这次没给出建议（\(response?.friendlyError ?? "")），先用示例演示。", "The model didn’t return a suggestion (\(response?.friendlyError ?? "")). Here’s an example instead.")
                text = Self.example(for: mode)
            }
            // Typing while it was written makes it stale, as in a real chat.
            guard let text, self.draft.trimmingCharacters(in: .whitespacesAndNewlines) == draft,
                  let frame = inputFrame else {
                overlay.hide()
                return
            }
            show(text, mode: mode, at: frame)
        }
    }

    private func show(_ text: String, mode: String, at frame: CGRect) {
        let ghost = mode == "complete"
            && overlay.showGhost(text, tags: [], caret: nil, input: frame, fontSize: 13, background: inputColor()) == .shown
        if !ghost {
            overlay.showBubble(text, notes: [], input: frame, fontSize: 13, rewrite: mode == "rewrite")
        }
        shown = (text, mode)
        mark(mode == "complete" ? .suggest : .rewrite)
    }

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard let current = shown else { return false }
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if code == 48 && mods.isEmpty { // Tab
                draft = current.text
                mark(current.mode == "complete" ? .accept : .replace)
                hideSuggestion()
                return true
            }
            if code == 53 { // Esc
                hideSuggestion()
                return true
            }
        }
        hideSuggestion()
        return false
    }

    func reset(detail: String) {
        generation += 1
        working = false
        hideSuggestion()
    }

    private func hideSuggestion() {
        shown = nil
        overlay.hide()
    }

    // MARK: - Sending

    /// Return in the input box: the message joins the chat.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        hideSuggestion()
        messages.append(PracticeMessage(fromMe: true, text: text))
        draft = ""
        mark(.send)
    }

    /// Replace only the built-in conversation. User drafts and sent replies
    /// remain intact when the interface language changes.
    func refreshLanguage() {
        let opening = Self.opening
        let texts = opening.map(\.text)
        guard texts != openingTexts else { return }
        reset(detail: "languageChanged")
        if messages.count >= openingTexts.count,
           Array(messages.prefix(openingTexts.count)).map(\.text) == openingTexts {
            messages.replaceSubrange(0..<openingTexts.count, with: opening)
        }
        openingTexts = texts
        note = nil
    }

    func restart() {
        reset(detail: "")
        messages = Self.opening
        openingTexts = messages.map(\.text)
        draft = ""
        done = []
        note = nil
    }
}
