import AppKit
import Testing
@testable import Tact

/// A drawn stand-in for Telegram for Mac at 2x: chat list, then the chat
/// with its header line, a wallpaper, and the input panel under a line.
/// Rects are in points, top-left origin.
private struct FakeTelegram {
    static let scale: CGFloat = 2
    let size = CGSize(width: 1000, height: 600)
    let context: CGContext
    static let panel = Pixels.Color(r: 255, g: 255, b: 255)

    init() {
        context = CGContext(data: nil, width: Int(size.width * Self.scale), height: Int(size.height * Self.scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let line = Pixels.Color(r: 222, g: 222, b: 222)
        fill(CGRect(x: 0, y: 0, width: 300, height: 600), Pixels.Color(r: 248, g: 248, b: 248))
        fill(CGRect(x: 300, y: 0, width: 0.5, height: 600), line)
        fill(CGRect(x: 300.5, y: 0, width: 699.5, height: 52), Self.panel)
        fill(CGRect(x: 300.5, y: 52, width: 699.5, height: 0.5), line)
        fill(CGRect(x: 300.5, y: 52.5, width: 699.5, height: 497.5), Pixels.Color(r: 160, g: 190, b: 150))
        fill(CGRect(x: 300.5, y: 550, width: 699.5, height: 0.5), line)
        fill(CGRect(x: 300.5, y: 550.5, width: 699.5, height: 49.5), Self.panel)
    }

    func fill(_ rect: CGRect, _ color: Pixels.Color) {
        context.setFillColor(CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                     blue: CGFloat(color.b) / 255, alpha: 1))
        context.fill(CGRect(x: rect.minX * Self.scale, y: (size.height - rect.maxY) * Self.scale,
                            width: rect.width * Self.scale, height: rect.height * Self.scale))
    }

    /// Text drawn at a top-left point; returns its box in capture pixels.
    @discardableResult
    func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat, color: NSColor) -> CGRect {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.systemFont(ofSize: fontSize * Self.scale)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        string.draw(at: NSPoint(x: point.x * Self.scale, y: (size.height - point.y) * Self.scale - font.ascender + font.descender))
        NSGraphicsContext.current = previous
        let width = string.size().width
        return CGRect(x: point.x * Self.scale, y: point.y * Self.scale, width: width, height: (font.ascender - font.descender))
    }

    var image: CGImage { context.makeImage()! }

    struct NotAChat: Error {}

    /// Pixels stay out of expectations: a failure would print every byte.
    func read() throws -> (Pixels, TelegramScreen.Layout) {
        guard let pixels = Pixels(image), let layout = TelegramScreen.layout(pixels, scale: Self.scale) else { throw NotAChat() }
        return (pixels, layout)
    }
}

struct TelegramScreenTests {
    @Test func theLayoutComesFromTheHeaderAndPanelLines() throws {
        let (_, layout) = try FakeTelegram().read()
        #expect(layout.chat.minX == 601 && layout.chat.maxX == 2000)
        #expect(layout.header.minY == 0 && layout.header.maxY == 104)
        #expect(layout.composer.minY == 1101 && layout.composer.maxY == 1200)
        let buttons = (TelegramScreen.attachWidth + TelegramScreen.buttonsWidth) * FakeTelegram.scale
        #expect(layout.typing.minX == layout.composer.minX + TelegramScreen.attachWidth * FakeTelegram.scale)
        #expect(layout.typing.width == layout.composer.width - buttons)
        #expect(layout.background == FakeTelegram.panel)
    }

    @Test func aChannelWithoutAnInputPanelIsNotAChat() throws {
        let window = FakeTelegram()
        window.fill(CGRect(x: 300.5, y: 550, width: 699.5, height: 0.5), Pixels.Color(r: 160, g: 190, b: 150))
        window.fill(CGRect(x: 300.5, y: 550.5, width: 699.5, height: 49.5), Pixels.Color(r: 160, g: 190, b: 150))
        #expect(throws: FakeTelegram.NotAChat.self) { try window.read() }
    }

    /// The hint's words differ with the app's language; its grey does not.
    @Test func typedTextIsToldFromTheHintByContrast() throws {
        let window = FakeTelegram()
        let hint = window.draw("Write a message…", at: CGPoint(x: 360, y: 566), size: 13, color: NSColor(white: 0.62, alpha: 1))
        let (pixels, layout) = try window.read()
        let hintLine = WeChatScreen.Line(text: "Write a message…", box: hint)
        var split = TelegramScreen.split([hintLine], in: layout, pixels: pixels)
        #expect(split.typed.isEmpty && split.hint == hintLine)

        let typedWindow = FakeTelegram()
        let typed = typedWindow.draw("明天见", at: CGPoint(x: 360, y: 566), size: 13, color: .black)
        let (typedPixels, typedLayout) = try typedWindow.read()
        let typedLine = WeChatScreen.Line(text: "明天见", box: typed)
        split = TelegramScreen.split([typedLine], in: typedLayout, pixels: typedPixels)
        #expect(split.typed == [typedLine] && split.hint == nil)
        #expect(TelegramScreen.draft(split.typed) == "明天见")
    }

    @Test func buttonsAndTheChatAreNotTyping() throws {
        let (pixels, layout) = try FakeTelegram().read()
        let attach = WeChatScreen.Line(text: "@", box: CGRect(x: 620, y: 1130, width: 30, height: 30))
        let send = WeChatScreen.Line(text: "Send", box: CGRect(x: 1900, y: 1130, width: 60, height: 30))
        let message = WeChatScreen.Line(text: "到了吗", box: CGRect(x: 700, y: 600, width: 120, height: 30))
        let split = TelegramScreen.split([attach, send, message], in: layout, pixels: pixels)
        #expect(split.typed.isEmpty && split.hint == nil)
    }

    @Test func theTitleIsTheLargestHeaderLine() {
        let header = [WeChatScreen.Line(text: "last seen recently", box: CGRect(x: 700, y: 64, width: 200, height: 22)),
                      WeChatScreen.Line(text: "Ann Lee", box: CGRect(x: 700, y: 30, width: 120, height: 30))]
        #expect(TelegramScreen.title(header) == "Ann Lee")
        #expect(TelegramScreen.title([]).isEmpty)
    }

    @Test func requestsAskThePluginForTheChatByItsHeader() throws {
        let header = [WeChatScreen.Line(text: "Ann Lee", box: CGRect(x: 700, y: 30, width: 120, height: 30))]
        let look = ScreenLook(title: "Ann Lee", draft: "ok", input: .zero, typing: .zero, anchor: .zero, hint: nil,
                              composer: FakeTelegram.panel, context: TelegramScreen.Context(header: header))
        let reader = TelegramScreen()
        let payload = reader.payload(id: "r1", platformID: "custom-tg", look: look)
        #expect(payload["op"] as? String == "suggest" && payload["platform_id"] as? String == "custom-tg")
        #expect(payload["input"] as? String == "ok" && payload["screen"] == nil)
        let lines = try #require(payload["ocr_lines"] as? [[String: Any]])
        #expect(lines.count == 1 && lines[0]["text"] as? String == "Ann Lee" && lines[0]["height"] as? Double == 30)
        let resolve = try #require(reader.resolvePayload(id: "r1", platformID: "custom-tg", look: look))
        #expect(resolve["op"] as? String == "resolve" && resolve["ocr_lines"] != nil)
        #expect(reader.hasContent(look))
        #expect(reader.summary(look).contains("顶部栏：Ann Lee"))
        #expect(WeChatAssistant().resolvePayload(id: "r1", platformID: "wechat", look: ScreenLook(
            title: "", draft: "", input: .zero, typing: .zero, anchor: .zero, hint: nil, composer: FakeTelegram.panel,
            context: WeChatScreen.Reading(title: "", isGroup: false, draft: "", rawLines: []))) == nil)
    }

    @Test func theShippedPluginDeclaresTheScreenStrategy() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plugins/telegram/manifest.json").path
        let manifest = try PlatformManifest.load(at: path)
        #expect(manifest.desktop.strategy == PlatformDesktop.screenStrategy)
        #expect(manifest.desktop.bundleIDs == [TelegramScreen.bundleID])
        #expect(manifest.setup?.commands?.first?.resolvedCommand(input: "", pluginDirectory: "/p") == "'/p'/tact-telegram login")
    }

    @Test func onlyAppsTactCanReadMayUseTheScreenStrategy() {
        var desktop = PlatformDesktop.defaultProfile
        desktop.strategy = PlatformDesktop.screenStrategy
        desktop.bundleIDs = [TelegramScreen.bundleID]
        #expect((try? desktop.validate()) != nil)
        desktop.bundleIDs = ["com.example.chat"]
        #expect(throws: PlatformError.self) { try desktop.validate() }
        desktop.strategy = "browser-v1"
        #expect(throws: PlatformError.self) { try desktop.validate() }
    }
}
