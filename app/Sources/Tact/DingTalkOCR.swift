import CoreGraphics

/// DingTalk read off a capture, for when its accessibility tree shows no
/// chat. The window has a blue bar across the top, the sidebar and the
/// conversation list on the left, and the chat on the right: a header under
/// the bar, the messages, then a line above the input area (a toolbar row,
/// the typing area, and the send row at the bottom).
enum DingTalkOCR {
    struct Layout: Equatable {
        var header: CGRect
        var messages: CGRect
        var input: CGRect
        var typing: CGRect
    }

    struct Reading: Equatable {
        var title: String
        var draft: String
        var lines: [WeChatScreen.TextBlock]
        var anchor: CGRect
        var hint: CGRect?
        var draftClipped: Bool
    }

    /// Under the blue bar: the chat's name, and on a second line its team.
    static let headerHeight: CGFloat = 50
    /// The toolbar between the line and the typing area.
    static let toolbarHeight: CGFloat = 40
    /// The send button and the 发送 / 换行 hint under the typing area.
    static let sendRowHeight: CGFloat = 48

    static func layout(_ pixels: Pixels, scale: CGFloat) -> Layout? {
        let pt = { (points: CGFloat) in Int(points * scale) }
        // The chat starts after the last column edge in the left part of
        // the window, past the conversation list and its scroll bar.
        guard let edge = WeChatScreen.columnSeparators(pixels).last(where: { $0.last < pixels.width * 6 / 10 }) else { return nil }
        let minX = edge.last, maxX = pixels.width
        guard maxX - minX > pt(300) else { return nil }
        let rows = WeChatScreen.rowSeparators(pixels, from: minX + pt(4), to: maxX - pt(24))
        guard let bar = rows.first(where: { $0.first > pt(16) && $0.first < pixels.height / 5 }),
              let line = rows.last(where: { $0.first >= pixels.height * 35 / 100 && $0.first <= pixels.height - pt(140) }),
              line.first > bar.last + pt(headerHeight + 60) else { return nil }
        let width = CGFloat(maxX - minX)
        let headerBottom = bar.last + pt(headerHeight)
        let typingTop = line.last + pt(toolbarHeight)
        return Layout(
            header: CGRect(x: CGFloat(minX), y: CGFloat(bar.last), width: width, height: CGFloat(headerBottom - bar.last)),
            messages: CGRect(x: CGFloat(minX), y: CGFloat(headerBottom), width: width, height: CGFloat(line.first - headerBottom)),
            input: CGRect(x: CGFloat(minX), y: CGFloat(line.last), width: width, height: CGFloat(pixels.height - line.last)),
            typing: CGRect(x: CGFloat(minX), y: CGFloat(typingTop), width: width,
                           height: CGFloat(max(pt(20), pixels.height - pt(sendRowHeight) - typingTop))))
    }

    static func read(_ image: CGImage, pixels: Pixels, layout: Layout, scale: CGFloat) throws -> Reading {
        let header = try WeChatScreen.recognize(image, in: layout.header)
        let messages = try WeChatScreen.recognize(image, in: layout.messages).filter { !ChatOCR.isFaint($0, pixels: pixels) }
        let typing = try WeChatScreen.recognize(image, in: layout.typing)
        let composer = ChatOCR.composer(typing, in: layout.typing, scale: scale, isHint: isHint)
        return Reading(title: WeChatScreen.title(from: header, in: layout.header).0, draft: composer.draft,
                       lines: ChatOCR.blocks(messages, in: layout.messages), anchor: composer.anchor, hint: composer.hint,
                       draftClipped: composer.clipped)
    }

    /// The empty box's hint.
    static func isHint(_ text: String) -> Bool {
        String(text.filter { !$0.isWhitespace }).range(of: #"^[|｜丨]?请输入消息[.。…⋯]*$"#, options: .regularExpression) != nil
    }
}
