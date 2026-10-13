import AppKit
import Testing
@testable import Tact

/// A drawn stand-in for WeChat's window at 2x: sidebar, chat list, chat
/// column with an input box below a separator line. Rects are in points,
/// top-left origin, like WeChatScreen's.
private struct FakeWindow {
    static let scale: CGFloat = 2
    let size: CGSize
    let context: CGContext

    static let list = Pixels.Color(r: 250, g: 250, b: 250)

    /// The input box's top line sits 130 points above the bottom.
    init(height: CGFloat = 600) {
        size = CGSize(width: 1000, height: height)
        context = CGContext(data: nil, width: Int(size.width * Self.scale), height: Int(size.height * Self.scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        fill(CGRect(x: 0, y: 0, width: 60, height: height), Pixels.Color(r: 46, g: 46, b: 46))
        fill(CGRect(x: 60, y: 0, width: 240, height: height), Pixels.Color(r: 247, g: 247, b: 247))
        fill(CGRect(x: 300, y: 0, width: 700, height: height), Self.list)
        fill(CGRect(x: 300, y: 0, width: 0.5, height: height), Self.line)
        fill(CGRect(x: 300, y: height - 130, width: 700, height: 0.5), Self.line)
    }

    static let line = Pixels.Color(r: 224, g: 224, b: 224)

    struct NotAChat: Error {}

    /// The window's pixels and layout. Pixels stay out of expectations:
    /// a failure would print every byte.
    func read() throws -> (Pixels, WeChatScreen.Layout) {
        guard let pixels = Pixels(image) else { throw NotAChat() }
        guard let layout = WeChatScreen.layout(pixels, scale: Self.scale) else { throw NotAChat() }
        return (pixels, layout)
    }

    func fill(_ rect: CGRect, _ color: Pixels.Color) {
        context.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                     blue: CGFloat(color.b) / 255, alpha: 1))
        context.fill(CGRect(x: rect.minX * Self.scale, y: (size.height - rect.maxY) * Self.scale,
                            width: rect.width * Self.scale, height: rect.height * Self.scale))
    }

    func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.systemFont(ofSize: fontSize * Self.scale)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
            .draw(at: NSPoint(x: point.x * Self.scale, y: (size.height - point.y) * Self.scale - font.ascender))
        NSGraphicsContext.current = previous
    }

    var image: CGImage { context.makeImage()! }

    /// WeChat's caret as measured on 4.1.13: solid green, 2 x 17 pt.
    static let caretGreen = Pixels.Color(r: 0, g: 202, b: 136)

    /// Types `draft` in WeChat's text colour and, unless the caret is
    /// between blinks, lights it `gap` points after the text. Returns the
    /// caret's rect in capture pixels.
    @discardableResult
    func type(_ draft: String, caretGap gap: CGFloat?) -> CGRect? {
        let point = CGPoint(x: 318, y: 486)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.systemFont(ofSize: 14 * Self.scale)
        let text = NSAttributedString(string: draft, attributes: [
            .font: font, .foregroundColor: NSColor(srgbRed: 34 / 255, green: 34 / 255, blue: 37 / 255, alpha: 1)])
        text.draw(at: NSPoint(x: point.x * Self.scale, y: (size.height - point.y) * Self.scale - font.ascender))
        NSGraphicsContext.current = previous
        guard let gap else { return nil }
        let midY = point.y + (font.ascender - font.descender) / Self.scale / 2
        let caret = CGRect(x: point.x + text.size().width / Self.scale + gap, y: midY - 8.5, width: 2, height: 17)
        fill(caret, Self.caretGreen)
        return CGRect(x: caret.minX * Self.scale, y: caret.minY * Self.scale,
                      width: caret.width * Self.scale, height: caret.height * Self.scale)
    }

    /// A line of text the way OCR reports it, in pixels.
    static func line(_ text: String, _ rect: CGRect) -> WeChatScreen.Line {
        WeChatScreen.Line(text: text, box: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                  width: rect.width * scale, height: rect.height * scale))
    }
}

struct WeChatScreenTests {
    @Test func theLayoutComesFromTheSeparators() throws {
        let (pixels, layout) = try FakeWindow().read()
        let corner = pixels.color(10, 10)
        #expect(corner == Pixels.Color(r: 46, g: 46, b: 46))
        #expect(layout.chat.minX == 601 && layout.chat.maxX == 2000)
        #expect(layout.header == CGRect(x: 601, y: 0, width: 1399, height: 100))
        #expect(layout.messages.minY == 100 && layout.messages.maxY == 940)
        #expect(layout.input.minY == 941 && layout.input.maxY == 1200)
        #expect(layout.background == FakeWindow.list)
    }

    @Test func typingIsReadAboveTheInputControls() throws {
        let (_, layout) = try FakeWindow().read()
        #expect(layout.typing.minY == layout.input.minY && layout.typing.width == layout.input.width)
        #expect(layout.typing.maxY == layout.input.maxY - WeChatScreen.controlsHeight * FakeWindow.scale)
        let hint = FakeWindow.line("按住鼠标 语音输入文字", CGRect(x: 318, y: 484, width: 150, height: 16))
        // Icons in the controls row that OCR took for characters.
        let icons = [FakeWindow.line("©", CGRect(x: 318, y: 566, width: 60, height: 18)),
                     FakeWindow.line("③", CGRect(x: 960, y: 566, width: 18, height: 18))]
        #expect(WeChatScreen.draft(from: [hint] + icons, in: layout.typing).isEmpty)
        let anchor = WeChatScreen.inputAnchor(from: [hint] + icons, in: layout.typing, scale: FakeWindow.scale)
        #expect(anchor.minX == hint.box.minX && anchor.midY == hint.box.midY)
    }

    /// Tact reads the draft again before showing a suggestion and before
    /// writing it; a caret that blinked in between must not count as an
    /// edit, nor reach the model as a "|".
    @Test(arguments: ["反驳", "好的", "ok"])
    func aLitCaretReadsLikeAnUnlitOne(draft: String) throws {
        let unlit = FakeWindow(), lit = FakeWindow()
        unlit.type(draft, caretGap: nil)
        lit.type(draft, caretGap: 1)
        let reader = WeChatAssistant()
        let before = try #require(try reader.titleAndDraft(unlit.image, scale: FakeWindow.scale))
        let after = try #require(try reader.titleAndDraft(lit.image, scale: FakeWindow.scale))
        #expect(before.draft == draft)
        #expect(after.draft == before.draft && after.title == before.title)
    }

    @Test func theCaretAnchorsTheSuggestion() throws {
        let window = FakeWindow()
        window.draw("小林", at: CGPoint(x: 330, y: 14), size: 16)
        let drawn = try #require(window.type("反驳", caretGap: 2.5))
        let look = try #require(try WeChatAssistant().look(window.image, scale: FakeWindow.scale))
        #expect(look.draft == "反驳")
        #expect(abs(look.anchor.minX - drawn.minX) <= 1 && abs(look.anchor.midY - drawn.midY) <= 2)
    }

    /// A window dragged while the model works: the same look, placed on
    /// the window where it is now.
    @MainActor
    @Test func aDraggedWindowCarriesItsLook() throws {
        let window = FakeWindow()
        window.draw("小林", at: CGPoint(x: 330, y: 14), size: 16)
        window.type("反驳", caretGap: 2.5)
        let look = try #require(try WeChatAssistant().look(window.image, scale: FakeWindow.scale))
        let view = ScreenAssistant<WeChatAssistant>.View(pid: 1, window: CGRect(x: 100, y: 80, width: 1000, height: 600),
                                                         scale: FakeWindow.scale, look: look)
        let dragged = view.moved(to: CGRect(x: 340, y: 20, width: 1000, height: 600))
        #expect(dragged.anchorFrame == view.anchorFrame.offsetBy(dx: 240, dy: -60))
        #expect(dragged.inputFrame == view.inputFrame.offsetBy(dx: 240, dy: -60))
        #expect(dragged.look.draft == "反驳" && dragged.scale == view.scale)
    }

    @Test func theCaretIsASolidGreenBar() throws {
        let lit = FakeWindow()
        let drawn = try #require(lit.type("在开会，晚点回你", caretGap: 2.5))
        let (pixels, layout) = try lit.read()
        let found = try #require(WeChatScreen.caret(pixels, in: layout.typing, scale: FakeWindow.scale))
        #expect(abs(found.minX - drawn.minX) <= 1 && abs(found.maxX - drawn.maxX) <= 1)
        #expect(abs(found.height - drawn.height) <= 2)

        // Strokes of typed text, a green send button, a striped emoji.
        let lookalikes = FakeWindow()
        lookalikes.type("||| lll III 丨丨", caretGap: nil)
        lookalikes.draw("💈🕯️🚦", at: CGPoint(x: 600, y: 486), size: 18)
        lookalikes.fill(CGRect(x: 920, y: 510, width: 64, height: 28), FakeWindow.caretGreen)
        let (otherPixels, otherLayout) = try lookalikes.read()
        #expect(WeChatScreen.caret(otherPixels, in: otherLayout.typing, scale: FakeWindow.scale) == nil)
    }

    /// WeChat 4.1 in a short window: no line between the list and the
    /// chat, whose colours differ by only 8 beside the rounded input box,
    /// and that box takes over a third of the height.
    @Test func aShortWindowWithAFaintListEdgeIsStillAChat() throws {
        let window = FakeWindow(height: 410)
        window.fill(CGRect(x: 60, y: 0, width: 240, height: 410), Pixels.Color(r: 240, g: 240, b: 240))
        window.fill(CGRect(x: 300, y: 0, width: 700, height: 410), FakeWindow.list)
        window.fill(CGRect(x: 300, y: 262, width: 700, height: 148), Pixels.Color(r: 248, g: 248, b: 248))
        window.fill(CGRect(x: 306, y: 266, width: 688, height: 131), FakeWindow.line)
        window.fill(CGRect(x: 307, y: 267, width: 686, height: 129), FakeWindow.list)
        let (_, layout) = try window.read()
        #expect(layout.chat.minX == 600 && layout.chat.maxX == 2000)
        #expect(abs(layout.input.minY - 266 * FakeWindow.scale) <= 2)
    }

    @Test func aWindowWithoutAnInputBoxIsNotAChat() throws {
        let window = FakeWindow()
        window.fill(CGRect(x: 300, y: 470, width: 700, height: 0.5), FakeWindow.list)
        #expect(throws: FakeWindow.NotAChat.self) { try window.read() }
    }

    @Test func titlesLoseTheirMemberCount() {
        let header = CGRect(x: 0, y: 0, width: 400, height: 100)
        let title = { (text: String) in
            WeChatScreen.title(from: [WeChatScreen.Line(text: text, box: CGRect(x: 20, y: 40, width: 80, height: 34))], in: header)
        }
        #expect(title("周末球局(23)") == ("周末球局", true))
        #expect(title("周末球局（23）") == ("周末球局", true))
        #expect(title("张三") == ("张三", false))
        #expect(WeChatScreen.title(from: [], in: header) == ("", false))
    }

    @Test func linesJoinLikeText() {
        #expect(WeChatScreen.joined("明天", "见") == "明天见")
        #expect(WeChatScreen.joined("see you", "tomorrow") == "see you tomorrow")
        #expect(WeChatScreen.joined("好的", "OK") == "好的OK")
        #expect(WeChatScreen.joinFragments([
            WeChatScreen.Line(text: "哈哈", box: CGRect(x: 100, y: 10, width: 40, height: 20)),
            WeChatScreen.Line(text: "好", box: CGRect(x: 160, y: 11, width: 20, height: 20)),
            WeChatScreen.Line(text: "下一行", box: CGRect(x: 100, y: 40, width: 60, height: 20)),
        ]).map(\.text) == ["哈哈好", "下一行"])
    }

    @Test func recognizedTextKeepsItsPlace() throws {
        let window = FakeWindow()
        window.draw("下午三点开会", at: CGPoint(x: 400, y: 100), size: 20)
        let lines = try WeChatScreen.recognize(window.image, in: CGRect(x: 600, y: 0, width: 1400, height: 940))
        let line = try #require(lines.first)
        #expect(line.text == "下午三点开会")
        #expect(abs(line.box.minX - 800) < 16 && abs(line.box.minY - 200) < 16)
    }

    @Test func aRequestCarriesTheReading() throws {
        let reading = WeChatScreen.Reading(title: "周末球局", isGroup: true, draft: "可以", rawLines: [
            WeChatScreen.TextBlock(text: "打球吗", x: 0.1, y: 0.2, width: 0.2, height: 0.03),
        ])
        let payload = WeChatAssistant.payload(id: "r1", reading: reading)
        #expect(payload["op"] as? String == "suggest" && payload["platform_id"] as? String == "wechat")
        #expect(payload["input"] as? String == "可以")
        let screen = try #require(payload["screen"] as? [String: Any])
        #expect(screen["title"] as? String == "周末球局" && screen["type"] as? String == "group")
        let lines = try #require(screen["lines"] as? [[String: Any]])
        #expect(lines.count == 1 && lines[0]["text"] as? String == "打球吗" && screen["messages"] == nil)
        #expect(WeChatAssistant.summary(reading).contains("打球吗"))
    }
}
