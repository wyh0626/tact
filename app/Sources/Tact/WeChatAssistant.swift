import CoreGraphics

/// How Tact reads WeChat for the screen assistant (see WeChatScreen): the
/// chat column's text with positions, for the model to make sense of.
struct WeChatAssistant: ScreenReader {
    static let platformID = "wechat"

    var name: String { L10n.tr("微信", "WeChat") }
    /// WeChat's own input font.
    let ghostFontSize: CGFloat = 14

    func look(_ image: CGImage, scale: CGFloat) throws -> ScreenLook<WeChatScreen.Reading>? {
        guard let pixels = Pixels(image), let layout = WeChatScreen.layout(pixels, scale: scale) else { return nil }
        // Use the same crops here and during validation. Whole-column OCR
        // can group input controls differently from input-only OCR.
        let header = try WeChatScreen.recognize(image, in: layout.header)
        let messages = try WeChatScreen.recognize(image, in: layout.messages)
        let (input, caret) = try WeChatScreen.recognizeTyping(image, pixels: pixels, layout: layout, scale: scale)
        let reading = WeChatScreen.readForModel(header + messages + input, layout: layout)
        guard !reading.title.isEmpty else { return nil }
        // The rounded input box can sit a little inside the chat column on
        // the right.
        var typing = layout.typing
        typing.size.width = max(0, typing.width - 16 * scale)
        return ScreenLook(title: reading.title, draft: reading.draft, input: layout.input, typing: typing,
                          anchor: caret ?? WeChatScreen.inputAnchor(from: input, in: layout.typing, scale: scale),
                          hint: WeChatScreen.placeholder(from: input, in: layout.typing),
                          composer: WeChatScreen.background(pixels, in: layout.typing), context: reading,
                          draftClipped: WeChatScreen.draftMayBeClipped(WeChatScreen.draftLines(from: input, in: layout.typing),
                                                                       in: layout.typing))
    }

    func titleAndDraft(_ image: CGImage, scale: CGFloat) throws -> (title: String, draft: String)? {
        guard let pixels = Pixels(image), let layout = WeChatScreen.layout(pixels, scale: scale) else { return nil }
        let title = WeChatScreen.title(from: try WeChatScreen.recognize(image, in: layout.header), in: layout.header).0
        let input = try WeChatScreen.recognizeTyping(image, pixels: pixels, layout: layout, scale: scale).lines
        return (title, WeChatScreen.draft(from: input, in: layout.typing))
    }

    func hasContent(_ look: ScreenLook<WeChatScreen.Reading>) -> Bool {
        !look.context.rawLines.isEmpty || !look.draft.isEmpty
    }

    func payload(id: String, platformID: String, look: ScreenLook<WeChatScreen.Reading>) -> [String: Any] {
        Self.payload(id: id, reading: look.context)
    }

    func summary(_ look: ScreenLook<WeChatScreen.Reading>) -> String {
        Self.summary(look.context)
    }

    static func payload(id: String, reading: WeChatScreen.Reading) -> [String: Any] {
        // A title without a member count may still be a group: the model
        // tells from the messages.
        [
            "op": "suggest",
            "request_id": id,
            "platform_id": platformID,
            "input": reading.draft,
            "screen": ["title": reading.title, "type": reading.isGroup ? "group" : "",
                       "lines": reading.rawLines.map(\.payload)] as [String: Any],
        ]
    }

    /// What test mode shows: enough to tell whether the reading is right.
    static func summary(_ reading: WeChatScreen.Reading) -> String {
        let clip = { (text: String) in text.count > 24 ? String(text.prefix(24)) + "…" : text }
        let blocks = reading.rawLines
        let title = reading.title.isEmpty ? L10n.tr("没读到名字", "Name not detected") : reading.title
        let draft = reading.draft.isEmpty ? L10n.tr("空", "Empty") : clip(reading.draft)
        var lines = [L10n.tr("「\(title)」", "“\(title)”"),
                     L10n.tr("聊天区 OCR 原文（末尾 \(min(3, blocks.count)) / 共 \(blocks.count) 段）", "Raw chat OCR (last \(min(3, blocks.count)) of \(blocks.count) blocks)")]
        lines += blocks.suffix(3).map { clip($0.text) }
        lines.append(L10n.tr("输入框：\(draft)", "Input: \(draft)"))
        lines.append(L10n.tr("测试模式未调用 AI", "Test mode did not call AI"))
        return lines.joined(separator: "\n")
    }
}
