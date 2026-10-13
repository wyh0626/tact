import AppKit

/// What one look at a chat window found. Rectangles are in pixels of the
/// capture, top-left origin.
struct ScreenLook<Context: Sendable>: Sendable {
    /// The open chat's name, to tell the same chat again later.
    var title: String
    var draft: String
    /// The whole input area: cards and notes sit above it.
    var input: CGRect
    /// Where typing shows, for ghost text.
    var typing: CGRect
    /// The caret, or where typing starts.
    var anchor: CGRect
    /// The empty input's hint, for ghost text to cover.
    var hint: CGRect?
    /// The input's own colour, for ghost text to sit on.
    var composer: Pixels.Color
    /// What the app's reader passes on to the engine.
    var context: Context
    /// The draft runs past what the input box shows, so what was read may
    /// be only part of it: a rewrite must not replace it.
    var draftClipped = false
}

/// How to read one chat app's window, for apps that offer neither
/// accessibility nor a way to read their input box.
protocol ScreenReader: Sendable {
    associatedtype Context: Sendable
    /// The app's name, in what the user is told.
    var name: String { get }
    /// The app's own input font, so ghost text reads as part of the box.
    var ghostFontSize: CGFloat { get }
    /// One capture, read; nil when the window shows no open chat.
    func look(_ image: CGImage, scale: CGFloat) throws -> ScreenLook<Context>?
    /// The title and draft a fresh capture shows, to check a look still holds.
    func titleAndDraft(_ image: CGImage, scale: CGFloat) throws -> (title: String, draft: String)?
    /// Whether the look holds anything to suggest from.
    func hasContent(_ look: ScreenLook<Context>) -> Bool
    func payload(id: String, platformID: String, look: ScreenLook<Context>) -> [String: Any]
    /// For test mode, when a plugin finds the chat: the request that asks
    /// which chat the engine takes this for.
    func resolvePayload(id: String, platformID: String, look: ScreenLook<Context>) -> [String: Any]?
    /// What test mode shows: enough to tell whether the reading is right.
    func summary(_ look: ScreenLook<Context>) -> String
}

extension ScreenReader {
    func resolvePayload(id: String, platformID: String, look: ScreenLook<Context>) -> [String: Any]? { nil }
}

/// The keyboard side of a screen assistant, for the controller.
@MainActor
protocol ScreenSession: AnyObject {
    func trigger(_ app: NSRunningApplication)
    /// Returns true to swallow the event.
    func handle(type: CGEventType, event: CGEvent) -> Bool
    func reset(detail: String)
}

enum ScreenError: LocalizedError {
    case notAChat(String)

    var errorDescription: String? {
        switch self {
        case .notAChat(let app): return "没认出\(app)的聊天界面：先打开一个聊天"
        }
    }
}

/// Suggestions in an app read off the screen. The hotkey reads the open chat
/// and the draft; the suggestion shows as ghost text over an empty input, or
/// as a card above it; Tab pastes it in. Every suggestion is checked against
/// a fresh look at the window (same chat, same draft) before it is shown and
/// before it is pasted. Nothing is ever sent.
@MainActor
final class ScreenAssistant<Reader: ScreenReader>: ScreenSession {
    /// One look at the window, placed on screen.
    struct View {
        let pid: pid_t
        /// Accessibility coordinates: global points, top-left origin.
        let window: CGRect
        let scale: CGFloat
        let look: ScreenLook<Reader.Context>

        func onScreen(_ rect: CGRect) -> CGRect {
            CGRect(x: window.minX + rect.minX / scale, y: window.minY + rect.minY / scale,
                   width: rect.width / scale, height: rect.height / scale)
        }

        var inputFrame: CGRect { onScreen(look.input) }
        var typingFrame: CGRect { onScreen(look.typing) }
        var anchorFrame: CGRect { onScreen(look.anchor) }

        /// The same look in the window dragged to `frame`, its size unchanged.
        func moved(to frame: CGRect) -> View {
            View(pid: pid, window: frame, scale: scale, look: look)
        }
    }

    private struct Shown {
        let requestID: String
        let view: View
        let chatID: String
        let text: String
        let mode: String
        let shownAt: Date

        /// The same suggestion on the window dragged to `frame`.
        func moved(to frame: CGRect) -> Shown {
            Shown(requestID: requestID, view: view.moved(to: frame), chatID: chatID, text: text, mode: mode, shownAt: shownAt)
        }
    }

    private enum State {
        case idle
        case working(String)
        case shown(Shown)
    }

    let reader: Reader
    let platformID: String
    private let overlay: Overlay
    private let capture: HeaderReader
    private let callEngine: ([String: Any], EngineCall) async throws -> [String: Any]
    private let sendFeedback: ([String: Any]) -> Void
    /// Read only, show what was read, and skip the model.
    var testMode: () -> Bool = { false }
    private var state: State = .idle
    private var call: EngineCall?
    private var watchTimer: Timer?
    /// A click landed on the window since the hotkey, to drag it say, and
    /// may have taken the keyboard from the input box.
    private var windowClicked = false
    private static var fontSize: CGFloat { 13 }

    init(reader: Reader, platformID: String, overlay: Overlay, capture: HeaderReader,
         callEngine: @escaping ([String: Any], EngineCall) async throws -> [String: Any],
         sendFeedback: @escaping ([String: Any]) -> Void) {
        self.reader = reader
        self.platformID = platformID
        self.overlay = overlay
        self.capture = capture
        self.callEngine = callEngine
        self.sendFeedback = sendFeedback
    }

    // MARK: - Trigger

    func trigger(_ app: NSRunningApplication) {
        reset(detail: "retriggered")
        let pid = app.processIdentifier
        guard let window = AX.windowFrame(pid: pid) else {
            Log.info("\(reader.name)：拿不到窗口位置")
            NSSound.beep()
            return
        }
        let id = UUID().uuidString
        state = .working(id)
        windowClicked = false
        Task { await run(id: id, pid: pid, window: window, started: Date()) }
    }

    private func isCurrent(_ id: String) -> Bool {
        if case .working(let current) = state, current == id { return true }
        return false
    }

    private func fail(_ message: String, near rect: CGRect) {
        state = .idle
        call = nil
        overlay.showToast(message, input: rect, duration: 3, kind: .warning)
        Log.info("\(reader.name)：\(message)")
    }

    /// Where to say something before the input box is known.
    private static func bottom(of window: CGRect) -> CGRect {
        CGRect(x: window.minX, y: window.maxY - 140, width: window.width, height: 140)
    }

    private func run(id: String, pid: pid_t, window: CGRect, started: Date) async {
        let view: View
        do {
            view = try await look(pid: pid, window: window)
        } catch {
            guard isCurrent(id) else { return }
            fail((error as? LocalizedError)?.errorDescription ?? "\(error)", near: Self.bottom(of: window))
            return
        }
        guard isCurrent(id) else { return }
        Log.info("\(reader.name)：读完画面，用时 \(ms(since: started)) ms")
        if testMode() {
            var summary = reader.summary(view.look)
            if let payload = reader.resolvePayload(id: id, platformID: platformID, look: view.look) {
                let raw = try? await callEngine(payload, EngineCall())
                guard isCurrent(id) else { return }
                let r = EngineResponse(raw ?? [:])
                summary += "\n" + (r.ok ? "认成：\(r.chatTitle ?? "?")" : "没认出：\(raw == nil ? "连不上引擎" : r.friendlyError)")
            }
            state = .idle
            overlay.showToast(summary, input: view.inputFrame, duration: 8)
            return
        }
        guard reader.hasContent(view.look) else {
            fail("这个聊天里没读到消息", near: view.inputFrame)
            return
        }
        overlay.showWorking(caret: view.anchorFrame, input: view.inputFrame, fontSize: Self.fontSize)
        // A resize hides the working pixels; the suggestion is placed on
        // the window as it is once ready.
        overlay.follow(pid: view.pid, frame: view.window)
        let token = EngineCall()
        call = token
        let raw: [String: Any]
        do {
            raw = try await callEngine(reader.payload(id: id, platformID: platformID, look: view.look), token)
        } catch EngineError.cancelled {
            return
        } catch {
            guard isCurrent(id) else { return }
            fail((error as? LocalizedError)?.errorDescription ?? "\(error)", near: view.inputFrame)
            return
        }
        guard isCurrent(id) else { return }
        call = nil
        let r = EngineResponse(raw)
        guard raw["platform_id"] as? String == platformID else {
            fail("引擎还不认识\(reader.name)，请退出并重新打开 Tact", near: view.inputFrame)
            return
        }
        guard r.ok else {
            fail(r.friendlyError, near: view.inputFrame)
            return
        }
        let chatID = r.chatID ?? view.look.title
        guard let text = r.suggestion, !text.isEmpty else {
            state = .idle
            overlay.showToast("这次不建议", input: view.inputFrame, duration: 1.5)
            return
        }
        await AX.waitForStillWindow(pid: view.pid, from: view.window)
        guard isCurrent(id) else { return }
        guard let now = await current(view), isCurrent(id) else {
            guard isCurrent(id) else { return }
            state = .idle
            overlay.showToast("会话或输入框变了，建议作废", input: view.inputFrame, duration: 1.5)
            feedback(id, "voided", chatID: chatID, detail: "changed_before_display")
            return
        }
        let shown = Shown(requestID: id, view: now, chatID: chatID, text: text, mode: r.mode, shownAt: Date())
        let asGhost = r.mode == "complete" && showGhost(text, tags: r.shortNotes, in: now)
        if !asGhost {
            let copyOnly = r.mode == "rewrite" && now.look.draftClipped
            overlay.showBubble(text, notes: r.notes, input: now.inputFrame, fontSize: Self.fontSize, rewrite: r.mode == "rewrite",
                               footer: copyOnly ? "草稿可能没读全  ·  TAB 复制  ·  ESC 取消" : nil)
        }
        state = .shown(shown)
        overlay.follow(pid: now.pid, frame: now.window) { [weak self] in
            guard let self, case .shown(let current) = self.state, current.requestID == id else { return }
            self.dismiss(current, event: "voided", detail: "window_resized")
        }
        startWatch()
        feedback(id, "shown", chatID: chatID, mode: r.mode, suggestionLen: text.count,
                 latency: ms(since: started), detail: asGhost ? "ghost" : "bubble")
        Log.info("\(reader.name)：建议已显示，\(text.count) 字，总耗时 \(ms(since: started)) ms（引擎 \(r.timing)）")
    }

    /// A reply to an empty input box shows as grey text where typing
    /// starts, over the box's hint. False when it does not fit there; the
    /// caller shows a card instead.
    private func showGhost(_ text: String, tags: [String], in view: View) -> Bool {
        let anchor = view.anchorFrame
        let cover = view.look.hint.map { view.onScreen($0).maxX - anchor.minX + 4 }
        let color = view.look.composer
        let background = NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                 blue: CGFloat(color.b) / 255, alpha: 1)
        switch overlay.showGhost(text, tags: tags, caret: anchor, input: view.typingFrame, fontSize: reader.ghostFontSize,
                                 background: background, cover: cover) {
        case .shown:
            return true
        case .tooWide, .tooTall:
            Log.info("\(reader.name)：建议在输入框里放不下（\(text.count) 字），改用气泡")
            return false
        }
    }

    /// Captures the window and reads the chat in it.
    private func look(pid: pid_t, window: CGRect) async throws -> View {
        let image = try await capture.captureWindow(pid: pid, windowFrame: window)
        let scale = CGFloat(image.width) / max(1, window.width)
        let reader = reader
        let found = try await Task.detached(priority: .userInitiated) { try reader.look(image, scale: scale) }.value
        guard let found else { throw ScreenError.notAChat(reader.name) }
        return View(pid: pid, window: window, scale: scale, look: found)
    }

    /// `view` as the window shows it now: the same chat and draft, in a
    /// window that may have been dragged or resized since. Nil when the
    /// app left the front or the chat or draft changed.
    private func current(_ view: View) async -> View? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == view.pid,
              let frame = AX.windowFrame(pid: view.pid) else {
            Log.info("\(reader.name)：窗口不在前台了")
            return nil
        }
        let now: View
        let reading: (title: String, draft: String)
        if frame.size == view.window.size {
            now = view.moved(to: frame)
            guard let read = await currentTitleAndDraft(now) else {
                Log.info("\(reader.name)：重新读画面失败")
                return nil
            }
            reading = read
        } else {
            // A new size lays the window out anew: read all of it again.
            guard let fresh = try? await look(pid: view.pid, window: frame) else {
                Log.info("\(reader.name)：窗口改了大小，重新读画面失败")
                return nil
            }
            now = fresh
            reading = (fresh.look.title, fresh.look.draft)
        }
        if let change = TextUtil.change(from: (view.look.title, view.look.draft), to: reading) {
            Log.info("\(reader.name)：\(change)")
            return nil
        }
        return now
    }

    private func currentTitleAndDraft(_ view: View) async -> (title: String, draft: String)? {
        guard let image = try? await capture.captureWindow(pid: view.pid, windowFrame: view.window) else { return nil }
        let scale = CGFloat(image.width) / max(1, view.window.width)
        let reader = reader
        return try? await Task.detached(priority: .userInitiated) { try reader.titleAndDraft(image, scale: scale) }.value
    }

    // MARK: - Shown

    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type != .keyDown { windowClicked = true }
        guard case .shown(let shown) = state else { return false }
        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if code == 48 && mods.isEmpty { // Tab
                accept(shown)
                return true
            }
            if code == 53 { // Esc
                dismiss(shown, event: "dismissed", detail: "esc")
                return true
            }
            dismiss(shown, event: "dismissed", detail: "typing")
            return false
        }
        Task { await settleClick(on: shown) }
        return false
    }

    /// A click ends the suggestion, unless it dragged the window: then the
    /// suggestion stays, and the overlay comes back where the window stopped.
    private func settleClick(on shown: Shown) async {
        while NSEvent.pressedMouseButtons & 1 != 0 {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        guard case .shown(let current) = state, current.requestID == shown.requestID else { return }
        guard let frame = AX.windowFrame(pid: current.view.pid), frame != current.view.window else {
            dismiss(current, event: "dismissed", detail: "click")
            return
        }
        // A resize is the overlay's to end; a drag keeps the suggestion.
        if frame.size == current.view.window.size { state = .shown(current.moved(to: frame)) }
    }

    /// The app left the front, the settings changed, or a new trigger came.
    func reset(detail: String = "app_deactivated") {
        switch state {
        case .shown(let shown):
            dismiss(shown, event: "voided", detail: detail)
        case .working:
            call?.cancel()
            call = nil
            state = .idle
            overlay.hide()
        case .idle:
            break
        }
    }

    private func dismiss(_ shown: Shown, event: String, detail: String) {
        stopWatch()
        overlay.hide()
        state = .idle
        feedback(shown.requestID, event, chatID: shown.chatID, mode: shown.mode,
                 suggestionLen: shown.text.count, latency: ms(since: shown.shownAt), detail: detail)
    }

    private func startWatch() {
        stopWatch()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchTick() }
        }
    }

    private func stopWatch() {
        watchTimer?.invalidate()
        watchTimer = nil
    }

    private func watchTick() {
        guard case .shown(let shown) = state else {
            stopWatch()
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != shown.view.pid {
            dismiss(shown, event: "voided", detail: "app_deactivated")
        } else if Date().timeIntervalSince(shown.shownAt) > 120 {
            dismiss(shown, event: "voided", detail: "timeout")
        }
    }

    // MARK: - Accept

    private func accept(_ shown: Shown) {
        stopWatch()
        state = .idle
        Task { await finishAccept(shown) }
    }

    private func finishAccept(_ shown: Shown) async {
        guard let view = await current(shown.view) else {
            overlay.showToast("会话或输入框变了，没有写入", input: shown.view.inputFrame, duration: 2, kind: .warning)
            feedback(shown.requestID, "voided", chatID: shown.chatID, detail: "input_changed_on_accept")
            return
        }
        overlay.hide()
        if shown.mode == "rewrite" && view.look.draftClipped {
            Inserter.stage(shown.text, on: NSPasteboard.general)
            overlay.showToast("草稿超出了输入框能看到的范围，Tact 可能没读全，所以没有替换。建议已复制，确认后自己粘贴",
                              input: view.inputFrame, duration: 4)
            feedback(shown.requestID, "accepted", chatID: shown.chatID, mode: shown.mode,
                     suggestionLen: shown.text.count, latency: ms(since: shown.shownAt), detail: "clipboard")
            return
        }
        let before = view.look.draft
        if windowClicked {
            await Inserter.click(at: CGPoint(x: view.anchorFrame.midX, y: view.anchorFrame.midY))
        }
        let outcome = await Inserter.pasteUnread(shown.text, replacing: !before.isEmpty) {
            guard let draft = await self.currentTitleAndDraft(view)?.draft else { return false }
            return !draft.isEmpty && draft != before
        }
        switch outcome {
        case .inserted(let attempt):
            feedback(shown.requestID, "accepted", chatID: shown.chatID, mode: shown.mode,
                     suggestionLen: shown.text.count, latency: ms(since: shown.shownAt), detail: attempt.rawValue)
        case .mismatch, .notApplied:
            let onClipboard = outcome == .notApplied(leftOnClipboard: true)
            overlay.showToast(onClipboard ? "没看到建议进入输入框，它在剪贴板里，可以 ⌘V 粘贴" : "没能写入输入框",
                              input: view.inputFrame, duration: 3, kind: .warning)
            feedback(shown.requestID, "voided", chatID: shown.chatID, detail: "insert_failed")
        }
    }

    // MARK: - Helpers

    private func feedback(_ requestID: String, _ event: String, chatID: String, mode: String? = nil,
                          suggestionLen: Int? = nil, latency: Int? = nil, detail: String) {
        var payload: [String: Any] = ["op": "feedback", "platform_id": platformID, "request_id": requestID,
                                      "event": event, "chat_id": chatID, "detail": detail]
        if let mode { payload["mode"] = mode }
        if let suggestionLen { payload["suggestion_len"] = suggestionLen }
        if let latency { payload["latency_ms"] = latency }
        sendFeedback(payload)
    }

    private func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
