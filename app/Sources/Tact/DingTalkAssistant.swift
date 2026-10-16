import CoreGraphics

/// How Tact reads DingTalk for the screen assistant: the chat, its messages
/// and the draft through accessibility (see DingTalkScreen), the capture
/// only for the input box's colour and hint. When accessibility shows no
/// chat, the window is read off the screen instead (see DingTalkOCR).
struct DingTalkAssistant: ScreenReader {
    /// What reaches the engine: messages already split by sender, or the
    /// chat's text with positions for the model to split.
    enum Context: Sendable {
        case messages([DingTalkScreen.Message])
        case lines([WeChatScreen.TextBlock])
    }

    var name: String { L10n.tr("钉钉", "DingTalk") }
    /// DingTalk's input font.
    let ghostFontSize: CGFloat = 14
    /// Where DingTalk starts text in its empty input box, from the box's
    /// accessibility frame: where its hint shows before the box has focus.
    static let emptyStart = CGPoint(x: 20, y: 8)

    func look(_ image: CGImage, scale: CGFloat) throws -> ScreenLook<Context>? {
        guard let pixels = Pixels(image), let layout = DingTalkOCR.layout(pixels, scale: scale) else { return nil }
        let reading = try DingTalkOCR.read(image, pixels: pixels, layout: layout, scale: scale)
        guard !reading.title.isEmpty else { return nil }
        return ScreenLook(title: reading.title, draft: reading.draft, input: layout.input, typing: layout.typing,
                          anchor: reading.anchor, hint: reading.hint, composer: WeChatScreen.background(pixels, in: layout.typing),
                          context: .lines(reading.lines), draftClipped: reading.draftClipped)
    }

    func titleAndDraft(_ image: CGImage, scale: CGFloat) throws -> (title: String, draft: String)? {
        guard let pixels = Pixels(image), let layout = DingTalkOCR.layout(pixels, scale: scale) else { return nil }
        let reading = try DingTalkOCR.read(image, pixels: pixels, layout: layout, scale: scale)
        return reading.title.isEmpty ? nil : (reading.title, reading.draft)
    }

    func look(_ image: CGImage, scale: CGFloat, window: ScreenWindow) throws -> ScreenLook<Context>? {
        guard let tree = AXSnapshot.window(pid: window.pid), let reading = DingTalkScreen.read(tree) else {
            return try look(image, scale: scale)
        }
        let place = { (rect: CGRect) in
            CGRect(x: (rect.minX - window.frame.minX) * scale, y: (rect.minY - window.frame.minY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        let input = place(reading.input)
        // Where typing goes, from what the box shows: after the draft, or at
        // the hint of an empty box. DingTalk reports an empty box's caret at
        // the box's bottom, so its caret is not asked.
        let shown = ChatOCR.composer(try WeChatScreen.recognize(image, in: input), in: input, scale: scale,
                                     emptyStart: Self.emptyStart, isHint: DingTalkOCR.isHint)
        let hint = reading.draft.isEmpty ? shown.hint : nil
        var typing = input
        typing.size.width = max(0, input.maxX - shown.anchor.minX)
        typing.origin.x = shown.anchor.minX
        let composer = Pixels(image).map { WeChatScreen.background($0, in: input) } ?? Pixels.Color(r: 255, g: 255, b: 255)
        return ScreenLook(title: reading.title, draft: reading.draft, input: input, typing: typing, anchor: shown.anchor,
                          hint: hint, composer: composer, context: .messages(reading.messages))
    }

    func titleAndDraft(_ image: CGImage, scale: CGFloat, window: ScreenWindow) throws -> (title: String, draft: String)? {
        guard let tree = AXSnapshot.window(pid: window.pid), let reading = DingTalkScreen.read(tree) else {
            return try titleAndDraft(image, scale: scale)
        }
        return (reading.title, reading.draft)
    }

    func hasContent(_ look: ScreenLook<Context>) -> Bool {
        switch look.context {
        case .messages(let messages): return !messages.isEmpty || !look.draft.isEmpty
        case .lines(let lines): return !lines.isEmpty || !look.draft.isEmpty
        }
    }

    func payload(id: String, platformID: String, look: ScreenLook<Context>) -> [String: Any] {
        var screen: [String: Any] = ["title": look.title, "type": ""]
        switch look.context {
        case .messages(let messages): screen["messages"] = messages.map(\.payload)
        case .lines(let lines): screen["lines"] = lines.map(\.payload)
        }
        return ["op": "suggest", "request_id": id, "platform_id": platformID, "input": look.draft, "screen": screen]
    }

    func summary(_ look: ScreenLook<Context>) -> String {
        let clip = { (text: String) in text.count > 24 ? String(text.prefix(24)) + "…" : text }
        let title = look.title.isEmpty ? L10n.tr("没读到名字", "Name not detected") : look.title
        var lines = [L10n.tr("「\(title)」", "“\(title)”")]
        switch look.context {
        case .messages(let messages):
            lines.append(L10n.tr("辅助功能读到 \(messages.count) 条消息，最后 \(min(3, messages.count)) 条：",
                                 "Read \(messages.count) messages through Accessibility. The last \(min(3, messages.count)):"))
            lines += messages.suffix(3).map { message in
                let who = message.fromMe ? L10n.tr("我", "Me") : (message.sender.isEmpty ? L10n.tr("对方", "Them") : message.sender)
                return "\(who)：\(clip(message.text.replacingOccurrences(of: "\n", with: " ")))"
            }
        case .lines(let blocks):
            lines.append(L10n.tr("辅助功能没读到，改用截图识别（末尾 \(min(3, blocks.count)) / 共 \(blocks.count) 段）",
                                 "Accessibility found nothing; read off the screen (last \(min(3, blocks.count)) of \(blocks.count) blocks)"))
            lines += blocks.suffix(3).map { clip($0.text) }
        }
        lines.append(L10n.tr("输入框：\(look.draft.isEmpty ? "空" : clip(look.draft))", "Input: \(look.draft.isEmpty ? "Empty" : clip(look.draft))"))
        lines.append(L10n.tr("测试模式未调用 AI", "Test mode did not call AI"))
        return lines.joined(separator: "\n")
    }
}
