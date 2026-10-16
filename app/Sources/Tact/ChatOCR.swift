import CoreGraphics

/// Reading a chat off a capture once an app's rules have found where its
/// messages and input box are. All geometry is in capture pixels.
enum ChatOCR {
    /// The text in `area` with its place as fractions of the area, top to
    /// bottom, for the model to tell senders and messages apart.
    static func blocks(_ lines: [WeChatScreen.Line], in area: CGRect) -> [WeChatScreen.TextBlock] {
        lines.compactMap { line -> WeChatScreen.TextBlock? in
            guard area.contains(CGPoint(x: line.box.midX, y: line.box.midY)) else { return nil }
            let box = line.box.intersection(area)
            guard !box.isEmpty, box.width > 0, box.height > 0 else { return nil }
            return WeChatScreen.TextBlock(text: line.text, x: Double((box.minX - area.minX) / area.width),
                                          y: Double((box.minY - area.minY) / area.height),
                                          width: Double(box.width / area.width), height: Double(box.height / area.height))
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// Text whose darkest pixel is still near white: a watermark across the
    /// chat (DingTalk prints the user's name there), not a
    /// message. Text on any bubble, or in dark mode, has a darker pixel.
    static func isFaint(_ line: WeChatScreen.Line, pixels: Pixels) -> Bool {
        let box = line.box.integral
        for y in Int(box.minY)..<max(Int(box.minY) + 1, Int(box.maxY)) {
            for x in Int(box.minX)..<max(Int(box.minX) + 1, Int(box.maxX)) {
                let color = pixels.color(x, y)
                if (color.r + color.g + color.b) / 3 <= 200 { return false }
            }
        }
        return true
    }

    /// What an input box shows: the draft, where typing goes on, the hint
    /// an empty box shows, and whether the draft may run past the box.
    struct Composer: Equatable {
        var draft: String
        var anchor: CGRect
        var hint: CGRect?
        var clipped: Bool
    }

    /// The typed text in `typing`, told from the app's hint by `isHint`.
    /// `emptyStart` is where the app starts text in an empty box, in points
    /// from the box's top left: the hint is hidden once the box has focus.
    static func composer(_ lines: [WeChatScreen.Line], in typing: CGRect, scale: CGFloat,
                         emptyStart: CGPoint = CGPoint(x: 8, y: 8),
                         isHint: (String) -> Bool) -> Composer {
        let inside = WeChatScreen.joinFragments(lines.filter { typing.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) })
        let typed = inside.filter { !isHint($0.text) }
        let hint = typed.isEmpty ? inside.first { isHint($0.text) }?.box : nil
        let anchor: CGRect
        if let last = typed.last {
            anchor = CGRect(x: last.box.maxX, y: last.box.minY, width: scale, height: last.box.height)
        } else if let hint {
            anchor = CGRect(x: hint.minX, y: hint.minY, width: scale, height: hint.height)
        } else {
            let height = min(18 * scale, typing.height)
            anchor = CGRect(x: min(typing.minX + emptyStart.x * scale, typing.maxX - scale),
                            y: min(typing.minY + emptyStart.y * scale, typing.maxY - height), width: scale, height: height)
        }
        return Composer(draft: typed.map(\.text).reduce("") { WeChatScreen.joined($0, $1) }, anchor: anchor, hint: hint,
                        clipped: WeChatScreen.draftMayBeClipped(typed, in: typing))
    }
}
