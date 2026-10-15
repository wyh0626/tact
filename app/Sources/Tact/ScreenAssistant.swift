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

/// The window a capture was taken of, for readers that also ask the app's
/// accessibility tree.
struct ScreenWindow: Sendable {
    let pid: pid_t
    /// Accessibility coordinates: global points, top-left origin.
    let frame: CGRect
}

/// How to read one chat app's window, for apps whose input box Tact cannot
/// work through accessibility alone.
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
    /// The same, for readers that ask the app's accessibility tree first.
    func look(_ image: CGImage, scale: CGFloat, window: ScreenWindow) throws -> ScreenLook<Context>?
    func titleAndDraft(_ image: CGImage, scale: CGFloat, window: ScreenWindow) throws -> (title: String, draft: String)?
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

    func look(_ image: CGImage, scale: CGFloat, window: ScreenWindow) throws -> ScreenLook<Context>? {
        try look(image, scale: scale)
    }

    func titleAndDraft(_ image: CGImage, scale: CGFloat, window: ScreenWindow) throws -> (title: String, draft: String)? {
        try titleAndDraft(image, scale: scale)
    }
}

/// What an assistant asks of the desktop: which app is in front, where its
/// window is, and what the window shows.
struct ScreenDesk {
    var frontmost: @MainActor () -> pid_t?
    /// Accessibility coordinates: global points, top-left origin.
    var windowFrame: @MainActor (pid_t) -> CGRect?
    var capture: @MainActor (pid_t, CGRect) async throws -> CGImage
    /// Returns once a window being dragged or resized from the frame has stopped.
    var waitForStillWindow: @MainActor (pid_t, CGRect) async -> Void

    @MainActor
    static func live(_ reader: HeaderReader) -> ScreenDesk {
        ScreenDesk(frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                   windowFrame: { AX.windowFrame(pid: $0) },
                   capture: { try await reader.captureWindow(pid: $0, windowFrame: $1) },
                   waitForStillWindow: { await AX.waitForStillWindow(pid: $0, from: $1) })
    }
}

/// The keyboard side of a screen assistant, for the controller.
@MainActor
protocol ScreenSession: AnyObject {
    func trigger(_ app: NSRunningApplication)
    /// Returns true to swallow the event.
    func handle(type: CGEventType, event: CGEvent) -> Bool
    /// Ends the suggestion and any work on one.
    func reset(detail: String)
    /// The app left the front. A suggestion being made or shown is kept for
    /// when its chat is back.
    func leave()
}

extension ScreenSession {
    func leave() { reset(detail: "app_deactivated") }
}

enum ScreenError: LocalizedError {
    case notAChat(String)

    var errorDescription: String? {
        switch self {
        case .notAChat(let app): return L10n.tr("没认出\(app)的聊天界面：先打开一个聊天", "Could not recognize the \(app) chat interface. Open a chat first")
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
        let notes: [String]
        let shortNotes: [String]
        let started: Date
        let shownAt: Date

        /// The same suggestion on the window dragged to `frame`.
        func moved(to frame: CGRect) -> Shown { at(view.moved(to: frame), shownAt: shownAt) }

        /// The same suggestion over `view`, shown at `shownAt`.
        func at(_ view: View, shownAt: Date = Date()) -> Shown {
            Shown(requestID: requestID, view: view, chatID: chatID, text: text, mode: mode, notes: notes,
                  shortNotes: shortNotes, started: started, shownAt: shownAt)
        }
    }

    /// A ready suggestion whose chat is not in front: the user moved to
    /// another app or chat while it was made, or after it showed. It shows
    /// again once the chat is back with the same draft.
    private struct Waiting {
        let shown: Shown
        /// It was on screen before, so its "shown" was reported.
        let reported: Bool
        let since: Date
    }

    private enum State {
        case idle
        case working(String)
        case shown(Shown)
        case waiting(Waiting)
    }

    /// What a fresh look finds where a suggestion was made.
    private enum Presence {
        case same(View)
        /// Another app or chat is in front, or the window could not be read.
        case elsewhere
        /// The chat is in front with another draft.
        case draftChanged
    }

    let reader: Reader
    let platformID: String
    private let overlay: Overlay
    private let desk: ScreenDesk
    private let callEngine: ([String: Any], EngineCall) async throws -> [String: Any]
    private let sendFeedback: ([String: Any]) -> Void
    /// Read only, show what was read, and skip the model.
    var testMode: () -> Bool = { false }
    private var state: State = .idle
    private var call: EngineCall?
    private var watchTimer: Timer?
    private var waitTimer: Timer?
    private var resuming = false
    /// A failure while the user was in another app, said once they are back.
    private var missed: (message: String, pid: pid_t, near: CGRect, since: Date)?
    /// What will be said about a failure once the user is back, if anything.
    var heldFailure: String? { missed?.message }
    /// A click landed on the window since the hotkey, to drag it say, and
    /// may have taken the keyboard from the input box.
    private var windowClicked = false
    private static var fontSize: CGFloat { 13 }

    init(reader: Reader, platformID: String, overlay: Overlay, desk: ScreenDesk,
         callEngine: @escaping ([String: Any], EngineCall) async throws -> [String: Any],
         sendFeedback: @escaping ([String: Any]) -> Void) {
        self.reader = reader
        self.platformID = platformID
        self.overlay = overlay
        self.desk = desk
        self.callEngine = callEngine
        self.sendFeedback = sendFeedback
    }

    // MARK: - Trigger

    func trigger(_ app: NSRunningApplication) {
        reset(detail: "retriggered")
        let pid = app.processIdentifier
        guard let window = desk.windowFrame(pid) else {
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

    private func fail(_ id: String, _ message: String, near rect: CGRect, pid: pid_t) {
        state = .idle
        call = nil
        SuggestionActivity.shared.clear(id)
        Log.info("\(reader.name)：\(message)")
        guard isFront(pid) else {
            // Said over the chat tool only, once the user is back there.
            missed = (message, pid, rect, Date())
            startWaitTimer()
            return
        }
        overlay.showToast(message, input: rect, duration: 3, kind: .warning)
    }

    private func isFront(_ pid: pid_t) -> Bool {
        desk.frontmost() == pid
    }

    /// Where to say something before the input box is known.
    private static func bottom(of window: CGRect) -> CGRect {
        CGRect(x: window.minX, y: window.maxY - 140, width: window.width, height: 140)
    }

    private func run(id: String, pid: pid_t, window: CGRect, started: Date) async {
        SuggestionActivity.shared.set(.generating, for: id)
        let view: View
        do {
            view = try await look(pid: pid, window: window)
        } catch {
            guard isCurrent(id) else { return }
            fail(id, (error as? LocalizedError)?.errorDescription ?? "\(error)", near: Self.bottom(of: window), pid: pid)
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
                let problem = raw == nil ? L10n.tr("连不上引擎", "Cannot connect to the engine") : r.friendlyError
                summary += "\n" + (r.ok ? L10n.tr("认成：\(r.chatTitle ?? "?")", "Identified: \(r.chatTitle ?? "?")") : L10n.tr("没认出：\(problem)", "Not identified: \(problem)"))
            }
            state = .idle
            SuggestionActivity.shared.clear(id)
            overlay.showToast(summary, input: view.inputFrame, duration: 8)
            return
        }
        guard reader.hasContent(view.look) else {
            fail(id, L10n.tr("这个聊天里没读到消息", "No messages could be read in this chat"), near: view.inputFrame, pid: pid)
            return
        }
        if isFront(pid) {
            overlay.showWorking(caret: view.anchorFrame, input: view.inputFrame, fontSize: Self.fontSize)
            // A resize hides the working pixels; the suggestion is placed on
            // the window as it is once ready.
            overlay.follow(pid: view.pid, frame: view.window)
        }
        let token = EngineCall()
        call = token
        let raw: [String: Any]
        do {
            raw = try await callEngine(reader.payload(id: id, platformID: platformID, look: view.look), token)
        } catch EngineError.cancelled {
            return
        } catch {
            guard isCurrent(id) else { return }
            fail(id, (error as? LocalizedError)?.errorDescription ?? "\(error)", near: view.inputFrame, pid: pid)
            return
        }
        guard isCurrent(id) else { return }
        call = nil
        let r = EngineResponse(raw)
        guard raw["platform_id"] as? String == platformID else {
            fail(id, L10n.tr("引擎还不认识\(reader.name)，请退出并重新打开 Tact", "The engine does not recognize \(reader.name) yet. Quit and reopen Tact"), near: view.inputFrame, pid: pid)
            return
        }
        guard r.ok else {
            fail(id, r.friendlyError, near: view.inputFrame, pid: pid)
            return
        }
        let chatID = r.chatID ?? view.look.title
        guard let text = r.suggestion, !text.isEmpty else {
            state = .idle
            SuggestionActivity.shared.clear(id)
            if isFront(pid) { overlay.showToast(L10n.tr("这次不建议", "No suggestion this time"), input: view.inputFrame, duration: 1.5) }
            return
        }
        let made = Shown(requestID: id, view: view, chatID: chatID, text: text, mode: r.mode, notes: r.notes,
                         shortNotes: r.shortNotes, started: started, shownAt: started)
        if isFront(pid) {
            await desk.waitForStillWindow(view.pid, view.window)
            guard isCurrent(id) else { return }
        }
        let found = await presence(view)
        guard isCurrent(id) else { return }
        switch found {
        case .same(let now):
            let asGhost = present(made.at(now))
            feedback(id, "shown", chatID: chatID, mode: r.mode, suggestionLen: text.count,
                     latency: ms(since: started), detail: asGhost ? "ghost" : "bubble")
            Log.info("\(reader.name)：建议已显示，\(text.count) 字，总耗时 \(ms(since: started)) ms（引擎 \(r.timing)）")
        case .elsewhere:
            if isFront(pid) { overlay.hide() }
            wait(made, reported: false)
            Log.info("\(reader.name)：建议已生成，等回到原会话再显示")
        case .draftChanged:
            state = .idle
            SuggestionActivity.shared.clear(id)
            overlay.showToast(L10n.tr("输入框变了，建议作废", "The input changed. Suggestion discarded"), input: view.inputFrame, duration: 1.5)
            feedback(id, "voided", chatID: chatID, detail: "changed_before_display")
        }
    }

    /// Puts `shown` on screen; true when it went in as ghost text.
    @discardableResult
    private func present(_ shown: Shown) -> Bool {
        let now = shown.view
        let asGhost = shown.mode == "complete" && showGhost(shown.text, tags: shown.shortNotes, in: now)
        if !asGhost {
            let copyOnly = shown.mode == "rewrite" && now.look.draftClipped
            overlay.showBubble(shown.text, notes: shown.notes, input: now.inputFrame, fontSize: Self.fontSize, rewrite: shown.mode == "rewrite",
                               footer: copyOnly ? L10n.tr("草稿可能没读全  ·  TAB 复制  ·  ESC 取消", "Draft may be incomplete  ·  TAB Copy  ·  ESC Cancel") : nil)
        }
        stopWaitTimer()
        state = .shown(shown)
        SuggestionActivity.shared.clear(shown.requestID)
        overlay.follow(pid: now.pid, frame: now.window) { [weak self] in
            guard let self, case .shown(let current) = self.state, current.requestID == shown.requestID else { return }
            self.dismiss(current, event: "voided", detail: "window_resized")
        }
        startWatch()
        return asGhost
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
        let image = try await desk.capture(pid, window)
        let scale = CGFloat(image.width) / max(1, window.width)
        let reader = reader
        let screen = ScreenWindow(pid: pid, frame: window)
        let found = try await Self.offPool { try reader.look(image, scale: scale, window: screen) }
        guard let found else { throw ScreenError.notAChat(reader.name) }
        return View(pid: pid, window: window, scale: scale, look: found)
    }

    /// `view` as the window shows it now: the same chat and draft, in a
    /// window that may have been dragged or resized since. Nil when the
    /// app left the front or the chat or draft changed.
    private func current(_ view: View) async -> View? {
        if case .same(let now) = await presence(view) { return now }
        return nil
    }

    private func presence(_ view: View) async -> Presence {
        guard isFront(view.pid), let frame = desk.windowFrame(view.pid) else { return .elsewhere }
        let now: View
        let reading: (title: String, draft: String)
        if frame.size == view.window.size {
            now = view.moved(to: frame)
            guard let read = await currentTitleAndDraft(now) else {
                Log.info("\(reader.name)：重新读画面失败")
                return .elsewhere
            }
            reading = read
        } else {
            // A new size lays the window out anew: read all of it again.
            guard let fresh = try? await look(pid: view.pid, window: frame) else {
                Log.info("\(reader.name)：窗口改了大小，重新读画面失败")
                return .elsewhere
            }
            now = fresh
            reading = (fresh.look.title, fresh.look.draft)
        }
        guard TextUtil.same(view.look.title, reading.title) else { return .elsewhere }
        if let change = TextUtil.change(from: (view.look.title, view.look.draft), to: reading) {
            Log.info("\(reader.name)：\(change)")
            return .draftChanged
        }
        return .same(now)
    }

    private func currentTitleAndDraft(_ view: View) async -> (title: String, draft: String)? {
        guard let image = try? await desk.capture(view.pid, view.window) else { return nil }
        let scale = CGFloat(image.width) / max(1, view.window.width)
        let reader = reader
        let screen = ScreenWindow(pid: view.pid, frame: view.window)
        return try? await Self.offPool { try reader.titleAndDraft(image, scale: scale, window: screen) }
    }

    /// Reading a window blocks, on Vision and on the app's accessibility
    /// replies. It runs on a dispatch queue rather than one of Swift's few
    /// cooperative threads: Vision's text recognizer needs one of those
    /// free to finish.
    private static func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
        }
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

    /// Only typing ends a suggestion. After a click it stays while its chat
    /// and draft are on screen, following a dragged window; a click that
    /// opened another chat sets it aside until that chat is back.
    private func settleClick(on shown: Shown) async {
        while NSEvent.pressedMouseButtons & 1 != 0 {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        // Let the chat app draw what the click did before looking.
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard case .shown(let current) = state, current.requestID == shown.requestID else { return }
        let found = await presence(current.view)
        guard case .shown(let latest) = state, latest.requestID == shown.requestID else { return }
        switch found {
        case .same(let now):
            if now.window != latest.view.window { present(latest.at(now, shownAt: latest.shownAt)) }
        case .elsewhere:
            stopWatch()
            overlay.hide()
            wait(latest, reported: true)
        case .draftChanged:
            dismiss(latest, event: "dismissed", detail: "input_changed")
        }
    }

    /// The settings changed, or a new trigger came here or in another app.
    func reset(detail: String) {
        switch state {
        case .shown(let shown):
            dismiss(shown, event: "voided", detail: detail)
        case .working(let id):
            call?.cancel()
            call = nil
            state = .idle
            SuggestionActivity.shared.clear(id)
            overlay.hide()
        case .waiting(let waiting):
            drop(waiting, detail: detail)
        case .idle:
            break
        }
        missed = nil
    }

    func leave() {
        switch state {
        case .working:
            // The work goes on; its suggestion waits for this chat.
            overlay.hide()
        case .shown(let shown):
            stopWatch()
            overlay.hide()
            wait(shown, reported: true)
        case .waiting, .idle:
            break
        }
    }

    // MARK: - Waiting

    private func wait(_ shown: Shown, reported: Bool) {
        call = nil
        state = .waiting(Waiting(shown: shown, reported: reported, since: Date()))
        SuggestionActivity.shared.set(.ready, for: shown.requestID)
        startWaitTimer()
    }

    private func startWaitTimer() {
        stopWaitTimer()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.waitTick() }
        }
    }

    private func stopWaitTimer() {
        waitTimer?.invalidate()
        waitTimer = nil
    }

    private func drop(_ waiting: Waiting, detail: String) {
        stopWaitTimer()
        state = .idle
        SuggestionActivity.shared.clear(waiting.shown.requestID)
        feedback(waiting.shown.requestID, "voided", chatID: waiting.shown.chatID, mode: waiting.shown.mode,
                 suggestionLen: waiting.shown.text.count, detail: detail)
    }

    private func waitTick() {
        guard !resuming else { return }
        resuming = true
        Task {
            await checkWaiting()
            resuming = false
        }
    }

    /// One look for the waiting suggestion's chat. It looks at the window
    /// only while its app is in front: another app in front is all it takes
    /// to know the chat was left.
    func checkWaiting() async {
        if let missed {
            if Date().timeIntervalSince(missed.since) > SuggestionActivity.waitLifetime {
                self.missed = nil
            } else if isFront(missed.pid) {
                self.missed = nil
                overlay.showToast(L10n.tr("刚才的建议没生成出来：\(missed.message)", "The last suggestion could not be made: \(missed.message)"),
                                  input: missed.near, duration: 4, kind: .warning)
            }
        }
        guard case .waiting(let waiting) = state else {
            if missed == nil { stopWaitTimer() }
            return
        }
        if Date().timeIntervalSince(waiting.since) > SuggestionActivity.waitLifetime {
            drop(waiting, detail: "expired")
            return
        }
        guard isFront(waiting.shown.view.pid) else { return }
        await resume(waiting.shown.requestID)
    }

    private func isWaiting(_ id: String) -> Waiting? {
        if case .waiting(let waiting) = state, waiting.shown.requestID == id { return waiting }
        return nil
    }

    /// Shows the waiting suggestion when the user is back on its chat with
    /// the same draft, and drops it when the draft or the chat moved on.
    private func resume(_ id: String) async {
        guard let waiting = isWaiting(id) else { return }
        let found = await presence(waiting.shown.view)
        guard let current = isWaiting(id) else { return }
        switch found {
        case .elsewhere:
            break
        case .draftChanged:
            drop(current, detail: "input_changed")
        case .same(let now):
            // Newer messages leave it alone: the user can ask for a new one.
            guard isFront(now.pid) else { return }
            let shown = current.shown.at(now)
            let asGhost = present(shown)
            if !current.reported {
                feedback(id, "shown", chatID: shown.chatID, mode: shown.mode, suggestionLen: shown.text.count,
                         latency: ms(since: shown.started), detail: asGhost ? "ghost" : "bubble")
            }
            Log.info("\(reader.name)：回到原会话，显示等待中的建议")
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
        // A shown suggestion has no time limit: only typing ends it.
        guard !isFront(shown.view.pid) else { return }
        stopWatch()
        overlay.hide()
        wait(shown, reported: true)
    }

    // MARK: - Accept

    private func accept(_ shown: Shown) {
        stopWatch()
        state = .idle
        Task { await finishAccept(shown) }
    }

    private func finishAccept(_ shown: Shown) async {
        guard let view = await current(shown.view) else {
            overlay.showToast(L10n.tr("会话或输入框变了，没有写入", "The chat or input changed. Nothing was inserted"), input: shown.view.inputFrame, duration: 2, kind: .warning)
            feedback(shown.requestID, "voided", chatID: shown.chatID, detail: "input_changed_on_accept")
            return
        }
        overlay.hide()
        if shown.mode == "rewrite" && view.look.draftClipped {
            Inserter.stage(shown.text, on: NSPasteboard.general)
            overlay.showToast(L10n.tr("草稿超出了输入框能看到的范围，Tact 可能没读全，所以没有替换。建议已复制，确认后自己粘贴", "The draft extends beyond the visible input area, so Tact may not have read it all and left it unchanged. The suggestion was copied. Review it before pasting"),
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
            overlay.showToast(onClipboard ? L10n.tr("没看到建议进入输入框，它在剪贴板里，可以 ⌘V 粘贴", "The suggestion was not detected in the input. It is on the clipboard; press ⌘V to paste") : L10n.tr("没能写入输入框", "Could not insert into the input"),
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
