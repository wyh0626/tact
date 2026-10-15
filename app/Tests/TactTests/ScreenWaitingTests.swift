import AppKit
import Testing
@testable import Tact

/// A chat window whose open chat, draft and newest message a test sets.
private final class FakeChat: @unchecked Sendable {
    private let lock = NSLock()
    private var values = (title: "Lin", draft: "", latest: "How about 6:30?")

    var title: String {
        get { lock.withLock { values.title } }
        set { lock.withLock { values.title = newValue } }
    }
    var draft: String {
        get { lock.withLock { values.draft } }
        set { lock.withLock { values.draft = newValue } }
    }
    var latest: String {
        get { lock.withLock { values.latest } }
        set { lock.withLock { values.latest = newValue } }
    }
}

private struct FakeReader: ScreenReader {
    let chat: FakeChat
    var name: String { "Fake" }
    var ghostFontSize: CGFloat { 13 }

    func look(_ image: CGImage, scale: CGFloat) throws -> ScreenLook<String>? {
        let input = CGRect(x: 0, y: 200, width: 300, height: 60)
        return ScreenLook(title: chat.title, draft: chat.draft, input: input, typing: input,
                          anchor: CGRect(x: 0, y: 200, width: 1, height: 20), hint: nil,
                          composer: Pixels.Color(r: 255, g: 255, b: 255), context: chat.latest)
    }

    func titleAndDraft(_ image: CGImage, scale: CGFloat) throws -> (title: String, draft: String)? {
        (chat.title, chat.draft)
    }

    func hasContent(_ look: ScreenLook<String>) -> Bool { true }

    func payload(id: String, platformID: String, look: ScreenLook<String>) -> [String: Any] {
        ["op": "suggest", "request_id": id, "platform_id": platformID]
    }

    func summary(_ look: ScreenLook<String>) -> String { "" }
}

/// Holds the engine's answer until the test lets it through.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// One assistant on a fake desktop: the test decides which app is in front.
@MainActor
private final class Harness {
    let chat = FakeChat()
    let gate = Gate()
    var front: pid_t? = ProcessInfo.processInfo.processIdentifier
    var events: [(event: String, detail: String)] = []
    var engineCalls: [EngineCall] = []
    var reply: [String: Any] = ["ok": true, "platform_id": "fake", "suggestion": "Sure, see you at 6:30", "mode": "rewrite"]
    private(set) var assistant: ScreenAssistant<FakeReader>!

    init() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let image = Self.blank()
        let desk = ScreenDesk(frontmost: { [weak self] in self?.front },
                              windowFrame: { _ in window },
                              capture: { _, _ in image },
                              waitForStillWindow: { _, _ in })
        assistant = ScreenAssistant(
            reader: FakeReader(chat: chat), platformID: "fake", overlay: Overlay(level: .statusBar), desk: desk,
            callEngine: { [weak self] _, token in
                guard let self else { throw EngineError.cancelled }
                self.engineCalls.append(token)
                await self.gate.wait()
                return self.reply
            },
            sendFeedback: { [weak self] payload in
                let event = payload["event"] as? String ?? "", detail = payload["detail"] as? String ?? ""
                Task { @MainActor in self?.events.append((event, detail)) }
            })
    }

    func shown() -> Int { events.filter { $0.event == "shown" }.count }
    func voided(_ detail: String) -> Bool { events.contains { $0.event == "voided" && $0.detail == detail } }

    func trigger() { assistant.trigger(NSRunningApplication.current) }

    func leaveApp() {
        front = 1
        assistant.leave()
    }

    func returnToApp() { front = ProcessInfo.processInfo.processIdentifier }

    func click() {
        let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        _ = assistant.handle(type: .leftMouseDown, event: event)
    }

    func dismissed() -> Bool { events.contains { $0.event == "dismissed" || $0.event == "voided" } }

    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private static func blank() -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}

/// Moving away while a suggestion is made or shown keeps it for its chat.
@MainActor
@Suite(.serialized)
struct ScreenWaitingTests {
    @Test func leavingWhileItIsMadeShowsItOnReturn() async {
        let h = Harness()
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        #expect(SuggestionActivity.shared.kind == .generating)
        h.leaveApp()
        await h.gate.open()
        #expect(await h.until { SuggestionActivity.shared.kind == .ready })
        #expect(h.engineCalls.allSatisfy { !$0.isCancelled }, "leaving must not stop the engine")
        #expect(h.shown() == 0)

        h.returnToApp()
        await h.assistant.checkWaiting()
        #expect(await h.until { h.shown() == 1 })
        #expect(SuggestionActivity.shared.kind == .none)
        h.assistant.reset(detail: "test_done")
    }

    @Test func aReplyForAnotherChatWaitsForThatChat() async {
        let h = Harness()
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        h.chat.title = "Jay"
        await h.gate.open()
        #expect(await h.until { SuggestionActivity.shared.kind == .ready })
        await h.assistant.checkWaiting()
        #expect(h.shown() == 0, "the other chat is still open")

        h.chat.title = "Lin"
        await h.assistant.checkWaiting()
        #expect(await h.until { h.shown() == 1 })
        h.assistant.reset(detail: "test_done")
    }

    @Test func aNewerMessageKeepsTheWaitingSuggestion() async {
        let h = Harness()
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        h.leaveApp()
        await h.gate.open()
        #expect(await h.until { SuggestionActivity.shared.kind == .ready })
        h.chat.latest = "Actually, let's do another day"
        h.returnToApp()
        await h.assistant.checkWaiting()
        #expect(await h.until { h.shown() == 1 }, "the user decides whether to ask again")
        #expect(!h.voided("new_messages"))
        h.assistant.reset(detail: "test_done")
    }

    @Test func typingInTheChatDropsTheWaitingSuggestion() async {
        let h = Harness()
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        h.leaveApp()
        await h.gate.open()
        #expect(await h.until { SuggestionActivity.shared.kind == .ready })
        h.chat.draft = "I can't"
        h.returnToApp()
        await h.assistant.checkWaiting()
        #expect(await h.until { h.voided("input_changed") })
        #expect(h.shown() == 0)
    }

    @Test func aNewTriggerElsewhereEndsTheWaitingSuggestion() async {
        let h = Harness()
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        h.leaveApp()
        await h.gate.open()
        #expect(await h.until { SuggestionActivity.shared.kind == .ready })
        h.assistant.reset(detail: "superseded")
        #expect(await h.until { h.voided("superseded") })
        #expect(SuggestionActivity.shared.kind == .none)
        h.returnToApp()
        await h.assistant.checkWaiting()
        #expect(h.shown() == 0)
    }

    @Test func aShownSuggestionComesBackAfterLeavingTheApp() async {
        let h = Harness()
        await h.gate.open()
        h.trigger()
        #expect(await h.until { h.shown() == 1 })
        h.leaveApp()
        #expect(SuggestionActivity.shared.kind == .ready)
        h.returnToApp()
        await h.assistant.checkWaiting()
        #expect(SuggestionActivity.shared.kind == .none, "back on screen")
        #expect(h.shown() == 1, "a suggestion is reported shown once")
        h.assistant.reset(detail: "test_done")
    }

    @Test func aFailureWhileAwayIsToldOnReturn() async {
        let h = Harness()
        h.reply = ["ok": false, "platform_id": "fake", "error_code": "model_error", "error": "rate limited"]
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        h.leaveApp()
        await h.gate.open()
        #expect(await h.until { h.assistant.heldFailure != nil })
        #expect(SuggestionActivity.shared.kind == .none)
        await h.assistant.checkWaiting()
        #expect(h.assistant.heldFailure != nil, "still in another app")
        h.returnToApp()
        await h.assistant.checkWaiting()
        #expect(h.assistant.heldFailure == nil, "told once back")
    }

    @Test func aNewTriggerForgetsAHeldFailure() async {
        let h = Harness()
        h.reply = ["ok": false, "platform_id": "fake", "error_code": "model_error", "error": "rate limited"]
        h.trigger()
        #expect(await h.until { !h.engineCalls.isEmpty })
        h.leaveApp()
        await h.gate.open()
        #expect(await h.until { h.assistant.heldFailure != nil })
        h.assistant.reset(detail: "superseded")
        #expect(h.assistant.heldFailure == nil)
    }

    @Test func aClickInTheSameChatKeepsTheSuggestion() async {
        let h = Harness()
        await h.gate.open()
        h.trigger()
        #expect(await h.until { h.shown() == 1 })
        h.click()
        try? await Task.sleep(nanoseconds: 600_000_000)
        #expect(!h.dismissed(), "only typing ends a suggestion")
        #expect(SuggestionActivity.shared.kind == .none, "still on screen")
        h.assistant.reset(detail: "test_done")
    }

    @Test func aClickIntoAnotherChatSetsItAsideUntilBack() async {
        let h = Harness()
        await h.gate.open()
        h.trigger()
        #expect(await h.until { h.shown() == 1 })
        h.chat.title = "Jay"
        h.click()
        #expect(await h.until { SuggestionActivity.shared.kind == .ready })
        h.chat.title = "Lin"
        await h.assistant.checkWaiting()
        #expect(SuggestionActivity.shared.kind == .none, "back on screen")
        #expect(!h.dismissed())
        #expect(h.shown() == 1)
        h.assistant.reset(detail: "test_done")
    }

    @Test func aClickAfterTheDraftChangedEndsIt() async {
        let h = Harness()
        await h.gate.open()
        h.trigger()
        #expect(await h.until { h.shown() == 1 })
        h.chat.draft = "I can't"
        h.click()
        #expect(await h.until { h.events.contains { $0.event == "dismissed" && $0.detail == "input_changed" } })
    }

    @Test func activityBelongsToTheRequestThatSetIt() {
        let activity = SuggestionActivity()
        activity.set(.generating, for: "old")
        activity.set(.ready, for: "new")
        activity.clear("old")
        #expect(activity.kind == .ready, "a request that ends late leaves the newer one's state")
        activity.clear("new")
        #expect(activity.kind == .none)
    }

    @Test func menuBarMarkTellsGeneratingFromReady() {
        let plain = MenuBarMark.image(badged: false)
        let generating = MenuBarMark.image(badged: false, activity: .generating)
        let ready = MenuBarMark.image(badged: false, activity: .ready)
        #expect(plain.accessibilityDescription == "Tact")
        #expect(generating.accessibilityDescription != ready.accessibilityDescription)
        #expect(generating.tiffRepresentation != ready.tiffRepresentation)
        #expect(generating.isTemplate && ready.isTemplate)
    }
}
