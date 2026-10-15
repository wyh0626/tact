import ApplicationServices
import CoreGraphics

/// Finds the open chat in DingTalk's accessibility tree. DingTalk is a
/// native app: its messages are rows of a table, each with the sender's
/// avatar on their side, the sender's name beside it and the text in text
/// areas; the chat's name sits above the table and the input box below it.
enum DingTalkScreen {
    /// The download from dingtalk.com, and the Mac App Store build.
    static let bundleIDs = ["com.alibaba.DingTalkMac", "5ZSL2CJU2T.com.dingtalk.mac"]

    struct Message: Equatable, Sendable {
        var sender: String
        var fromMe: Bool
        var text: String

        var payload: [String: Any] { ["sender": sender, "from_me": fromMe, "text": text] }
    }

    /// The chat as read, in accessibility coordinates.
    struct Reading: Equatable, Sendable {
        var title: String
        var draft: String
        var input: CGRect
        var messages: [Message]
    }

    /// The most messages a reading passes on: the window loads more than
    /// it shows.
    static let messageLimit = 40

    static func read(_ window: AXNode) -> Reading? {
        guard let windowFrame = window.frame,
              let (list, table) = messageList(in: window, width: windowFrame.width),
              let input = inputBox(in: window, below: list) else { return nil }
        let title = window.all(kAXStaticTextRole).filter { text in
            guard let box = text.frame, !text.text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return box.midX > list.minX && box.midX < list.maxX && box.maxY <= list.minY + 2 && box.minY >= windowFrame.minY
        }.min { ($0.frame!.minY, $0.frame!.minX) < ($1.frame!.minY, $1.frame!.minX) }
        guard let title else { return nil }
        let rows = table.children.filter { $0.role == kAXRowRole }
        let messages = rows.compactMap { message(in: $0, list: list) }.suffix(messageLimit)
        return Reading(title: title.text.trimmingCharacters(in: .whitespaces), draft: input.text,
                       input: input.frame!, messages: Array(messages))
    }

    /// The visible part of the message table, and the table: the table
    /// furthest right that spans a good part of the window, in its scroll
    /// area. The conversation list and the sidebar are tables too, further left.
    static func messageList(in window: AXNode, width: CGFloat) -> (CGRect, AXNode)? {
        window.all(kAXScrollAreaRole).compactMap { area -> (CGRect, AXNode)? in
            guard let visible = area.frame, visible.width >= width * 0.3,
                  let table = area.children.first(where: { $0.role == kAXTableRole }) else { return nil }
            return (visible, table)
        }.max { $0.0.minX < $1.0.minX }
    }

    /// The largest editable text area under the message list.
    static func inputBox(in window: AXNode, below list: CGRect) -> AXNode? {
        window.all(kAXTextAreaRole).filter { area in
            guard area.editable, let box = area.frame else { return false }
            return box.minY >= list.maxY - 2 && box.midX > list.minX && box.midX < list.maxX
        }.max { $0.frame!.width * $0.frame!.height < $1.frame!.width * $1.frame!.height }
    }

    /// One row as a message: the side of its avatar tells who sent it. Rows
    /// without an avatar (dates, notices) or without text (pictures,
    /// files) are left out.
    static func message(in row: AXNode, list: CGRect) -> Message? {
        let parts = row.descendants
        var texts: [String] = []
        for part in parts where part.role == kAXTextAreaRole {
            let text = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && texts.last != text { texts.append(text) }
        }
        guard !texts.isEmpty, let avatar = parts.first(where: isAvatar)?.frame else { return nil }
        let mine = avatar.midX > list.midX
        // The name sits level with the top of the avatar, nearest it; tags
        // such as 机器人 follow it further out.
        let names = parts.filter { part in
            guard part.role == kAXButtonRole, let box = part.frame,
                  !part.text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
            return abs(box.minY - avatar.minY) <= avatar.height / 2
        }
        let name = mine ? names.max { $0.frame!.maxX < $1.frame!.maxX } : names.min { $0.frame!.minX < $1.frame!.minX }
        return Message(sender: mine ? "" : name?.text.trimmingCharacters(in: .whitespaces) ?? "",
                       fromMe: mine, text: texts.joined(separator: "\n"))
    }

    /// A square picture of avatar size.
    private static func isAvatar(_ node: AXNode) -> Bool {
        guard node.role == kAXImageRole, let box = node.frame else { return false }
        return (16...72).contains(box.width) && abs(box.width - box.height) <= 6
    }
}
