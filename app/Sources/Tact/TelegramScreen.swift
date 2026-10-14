import CoreGraphics
import Foundation

/// How Tact reads Telegram for Mac (ru.keepcoder.Telegram), which exposes
/// nothing to accessibility. Only the chat's identity and the draft come
/// from the screen: the header's text is matched against the plugin's chat
/// list, and the plugin reads the messages through Telegram's API.
struct TelegramScreen: ScreenReader {
    static let bundleID = "ru.keepcoder.Telegram"

    /// Rectangles in pixels of the capture, top-left origin.
    struct Layout: Equatable {
        var chat: CGRect
        var header: CGRect
        /// The input panel along the bottom of the chat.
        var composer: CGRect
        /// The panel without its buttons: attach on the left, emoji and
        /// voice on the right.
        var typing: CGRect
        var background: Pixels.Color
    }

    /// The header's text, for the engine to find the chat by.
    struct Context: Sendable {
        var header: [WeChatScreen.Line]
    }

    /// Where the header ends when no line marks it.
    static let headerHeight: CGFloat = 52
    static let attachWidth: CGFloat = 48
    static let buttonsWidth: CGFloat = 96
    /// Typed text stands out from the input panel by more than this;
    /// the panel's hint ("Write a message…") is a lighter grey.
    static let typedContrast = 110

    let name = "Telegram"
    let ghostFontSize: CGFloat = 13

    static func layout(_ pixels: Pixels, scale: CGFloat) -> Layout? {
        let pt = { (points: CGFloat) in Int(points * scale) }
        let column = WeChatScreen.chatColumn(width: pixels.width, separators: WeChatScreen.columnSeparators(pixels))
        guard column.maxX - column.minX > pt(attachWidth + buttonsWidth + 120) else { return nil }
        let rows = WeChatScreen.rowSeparators(pixels, from: column.minX + pt(4), to: column.maxX - pt(4))
        let header = rows.first { $0.first >= pt(30) && $0.first <= pt(90) }?.first ?? pt(headerHeight)
        guard let panel = rows.last(where: { $0.first >= pixels.height / 2 && $0.first <= pixels.height - pt(30) }),
              panel.first > header + pt(60) else { return nil }
        let width = CGFloat(column.maxX - column.minX)
        let composer = CGRect(x: CGFloat(column.minX), y: CGFloat(panel.last), width: width,
                              height: CGFloat(pixels.height - panel.last))
        let typing = CGRect(x: composer.minX + CGFloat(pt(attachWidth)), y: composer.minY,
                            width: composer.width - CGFloat(pt(attachWidth + buttonsWidth)), height: composer.height)
        return Layout(chat: CGRect(x: CGFloat(column.minX), y: 0, width: width, height: CGFloat(pixels.height)),
                      header: CGRect(x: CGFloat(column.minX), y: 0, width: width, height: CGFloat(header)),
                      composer: composer, typing: typing,
                      background: WeChatScreen.background(pixels, in: typing))
    }

    /// How far a line's darkest (or, in the dark theme, brightest) pixel
    /// stands from the panel's colour.
    static func contrast(of line: WeChatScreen.Line, on background: Pixels.Color, in pixels: Pixels) -> Int {
        let base = (background.r + background.g + background.b) / 3
        var most = 0
        let box = line.box.integral
        for y in stride(from: Int(box.minY), to: Int(box.maxY), by: 1) {
            for x in stride(from: Int(box.minX), to: Int(box.maxX), by: 1) {
                let c = pixels.color(x, y)
                most = max(most, abs((c.r + c.g + c.b) / 3 - base))
            }
        }
        return most
    }

    /// The typed lines and the hint, from what OCR found in the panel.
    static func split(_ lines: [WeChatScreen.Line], in layout: Layout, pixels: Pixels)
        -> (typed: [WeChatScreen.Line], hint: WeChatScreen.Line?) {
        let inside = WeChatScreen.joinFragments(lines.filter {
            layout.typing.contains(CGPoint(x: $0.box.midX, y: $0.box.midY))
        })
        let typed = inside.filter { contrast(of: $0, on: layout.background, in: pixels) > typedContrast }
        return (typed, typed.isEmpty ? inside.first : nil)
    }

    /// Telegram's panel grows with the draft up to a height, then scrolls:
    /// a first line at the very top means lines above it are hidden.
    static func scrolled(_ typed: [WeChatScreen.Line], in typing: CGRect) -> Bool {
        guard let first = typed.min(by: { $0.box.minY < $1.box.minY }) else { return false }
        return first.box.minY - typing.minY < first.box.height * 0.3
    }

    static func draft(_ typed: [WeChatScreen.Line]) -> String {
        typed.map(\.text).reduce("") { WeChatScreen.joined($0, $1) }
    }

    /// The chat's name: the largest text in the header (the status under
    /// it, "online" or "last seen", is smaller).
    static func title(_ header: [WeChatScreen.Line]) -> String {
        header.max { $0.box.height < $1.box.height }?.text ?? ""
    }

    func look(_ image: CGImage, scale: CGFloat) throws -> ScreenLook<Context>? {
        guard let pixels = Pixels(image), let layout = Self.layout(pixels, scale: scale) else { return nil }
        let header = try WeChatScreen.recognize(image, in: layout.header)
        let title = Self.title(header)
        guard !title.isEmpty else { return nil }
        let (typed, hint) = Self.split(try WeChatScreen.recognize(image, in: layout.typing), in: layout, pixels: pixels)
        let anchor: CGRect
        if let last = typed.last {
            anchor = CGRect(x: last.box.maxX, y: last.box.minY, width: scale, height: last.box.height)
        } else if let hint {
            anchor = CGRect(x: hint.box.minX, y: hint.box.minY, width: scale, height: hint.box.height)
        } else {
            let height = 16 * scale
            anchor = CGRect(x: layout.typing.minX + 4 * scale, y: layout.typing.midY - height / 2, width: scale, height: height)
        }
        return ScreenLook(title: title, draft: Self.draft(typed), input: layout.composer, typing: layout.typing,
                          anchor: anchor, hint: hint?.box, composer: layout.background, context: Context(header: header),
                          draftClipped: Self.scrolled(typed, in: layout.typing))
    }

    func titleAndDraft(_ image: CGImage, scale: CGFloat) throws -> (title: String, draft: String)? {
        guard let pixels = Pixels(image), let layout = Self.layout(pixels, scale: scale) else { return nil }
        let title = Self.title(try WeChatScreen.recognize(image, in: layout.header))
        let typed = Self.split(try WeChatScreen.recognize(image, in: layout.typing), in: layout, pixels: pixels).typed
        return (title, Self.draft(typed))
    }

    func hasContent(_ look: ScreenLook<Context>) -> Bool { !look.context.header.isEmpty }

    /// The engine matches the header against the plugin's chat list and
    /// reads the messages through the plugin.
    static func headerLines(_ look: ScreenLook<Context>) -> [[String: Any]] {
        look.context.header.map { ["text": $0.text, "height": Double($0.box.height)] }
    }

    func payload(id: String, platformID: String, look: ScreenLook<Context>) -> [String: Any] {
        ["op": "suggest", "request_id": id, "platform_id": platformID, "input": look.draft,
         "ocr_lines": Self.headerLines(look)]
    }

    func resolvePayload(id: String, platformID: String, look: ScreenLook<Context>) -> [String: Any]? {
        ["op": "resolve", "request_id": id, "platform_id": platformID, "ocr_lines": Self.headerLines(look)]
    }

    func summary(_ look: ScreenLook<Context>) -> String {
        let clip = { (text: String) in text.count > 24 ? String(text.prefix(24)) + "…" : text }
        let draft = look.draft.isEmpty ? L10n.tr("空", "Empty") : clip(look.draft)
        return [L10n.tr("顶部栏：", "Header: ") + look.context.header.map { clip($0.text) }.joined(separator: " / "),
                L10n.tr("输入框：\(draft)", "Input: \(draft)"),
                L10n.tr("测试模式未调用 AI", "Test mode did not call AI")].joined(separator: "\n")
    }
}
