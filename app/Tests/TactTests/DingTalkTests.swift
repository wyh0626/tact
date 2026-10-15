import AppKit
import ApplicationServices
import Testing
@testable import Tact

/// Recognizing text blocks; it runs on a dispatch queue so it leaves the
/// cooperative threads, which Vision's text recognizer needs, to the other
/// tests running alongside.
private func offPool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
}

/// A drawn window at 2x. Rects are in points, top-left origin.
private struct Canvas {
    static let scale: CGFloat = 2
    let size: CGSize
    let context: CGContext

    init(width: CGFloat, height: CGFloat, background: Pixels.Color) {
        size = CGSize(width: width, height: height)
        context = CGContext(data: nil, width: Int(width * Self.scale), height: Int(height * Self.scale),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        fill(CGRect(x: 0, y: 0, width: width, height: height), background)
    }

    func fill(_ rect: CGRect, _ color: Pixels.Color) {
        context.setFillColor(Self.cgColor(color))
        context.fill(CGRect(x: rect.minX * Self.scale, y: (size.height - rect.maxY) * Self.scale,
                            width: rect.width * Self.scale, height: rect.height * Self.scale))
    }

    func draw(_ text: String, at point: CGPoint, size fontSize: CGFloat, color: Pixels.Color = Pixels.Color(r: 20, g: 20, b: 20)) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.systemFont(ofSize: fontSize * Self.scale)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: Self.cgColor(color))!])
            .draw(at: NSPoint(x: point.x * Self.scale, y: (size.height - point.y) * Self.scale - font.ascender))
        NSGraphicsContext.current = previous
    }

    var image: CGImage { context.makeImage()! }
    var pixels: Pixels { Pixels(image)! }

    private static func cgColor(_ color: Pixels.Color) -> CGColor {
        CGColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }
}

/// DingTalk read off the screen: a blue bar, the sidebar and list, then the
/// chat with its header, a line above the input area, and a watermark.
private struct DingTalkWindow {
    static let line = Pixels.Color(r: 224, g: 224, b: 226)
    let canvas = Canvas(width: 1111, height: 753, background: Pixels.Color(r: 255, g: 255, b: 255))

    init(draft: String? = nil) {
        canvas.fill(CGRect(x: 0, y: 0, width: 1111, height: 40), Pixels.Color(r: 28, g: 107, b: 238))
        canvas.fill(CGRect(x: 140, y: 40, width: 260, height: 713), Pixels.Color(r: 247, g: 248, b: 250))
        for x in [140, 400] as [CGFloat] { canvas.fill(CGRect(x: x, y: 40, width: 0.5, height: 713), Self.line) }
        canvas.fill(CGRect(x: 400, y: 40, width: 711, height: 50), Pixels.Color(r: 239, g: 240, b: 241))
        canvas.draw("服务告警", at: CGPoint(x: 430, y: 46), size: 17)
        canvas.draw("归属于 运维组", at: CGPoint(x: 430, y: 70), size: 11, color: Pixels.Color(r: 130, g: 130, b: 130))
        canvas.fill(CGRect(x: 400, y: 430, width: 711, height: 0.5), Self.line)
        canvas.draw("钉钉", at: CGPoint(x: 900, y: 150), size: 20, color: Pixels.Color(r: 236, g: 236, b: 236))
        canvas.draw("集群名称：Infra-HK", at: CGPoint(x: 480, y: 200), size: 14)
        canvas.draw(draft ?? "请输入消息", at: CGPoint(x: 432, y: 482), size: 14,
                    color: draft == nil ? Pixels.Color(r: 160, g: 160, b: 160) : Pixels.Color(r: 20, g: 20, b: 20))
    }
}

struct DingTalkScreenTests {
    private static func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private static func row(_ parts: [AXNode]) -> AXNode {
        AXNode(role: kAXRowRole, children: [AXNode(role: kAXCellRole, children: parts)])
    }

    /// DingTalk's tree as measured on 7.6: the conversation list and the
    /// messages are tables in scroll areas, a message's text areas report
    /// no usable frame, and the input box sits under the messages.
    private static func window(input: Bool = true, draft: String = "") -> AXNode {
        let theirs = row([
            AXNode(role: kAXButtonRole, frame: frame(466, 100, 80, 16), text: "告警机器人"),
            AXNode(role: kAXButtonRole, frame: frame(550, 100, 40, 16), text: "机器人"),
            AXNode(role: kAXImageRole, frame: frame(420, 100, 36, 36)),
            AXNode(role: kAXImageRole, frame: frame(466, 120, 330, 40)),
            AXNode(role: kAXTextAreaRole, frame: frame(0, 753, 0, 0), text: "服务副本数为 0"),
            AXNode(role: kAXTextAreaRole, frame: frame(0, 753, 0, 0), text: "请及时处理"),
        ])
        let time = row([AXNode(role: kAXStaticTextRole, frame: frame(410, 180, 701, 20), text: "18:09")])
        let picture = row([AXNode(role: kAXImageRole, frame: frame(420, 210, 36, 36)),
                           AXNode(role: kAXImageRole, frame: frame(466, 210, 200, 120))])
        let mine = row([
            AXNode(role: kAXButtonRole, frame: frame(1000, 340, 40, 16), text: "王银鹤"),
            AXNode(role: kAXImageRole, frame: frame(1060, 340, 36, 36)),
            AXNode(role: kAXButtonRole, frame: frame(990, 400, 50, 16), text: "全部已读"),
            AXNode(role: kAXTextAreaRole, frame: frame(0, 753, 0, 0), text: "在看"),
        ])
        let list = AXNode(role: kAXScrollAreaRole, frame: frame(140, 40, 260, 713), children: [
            AXNode(role: kAXTableRole, frame: frame(140, 40, 260, 900),
                   children: [row([AXNode(role: kAXStaticTextRole, frame: frame(180, 60, 80, 16), text: "我（王银鹤）")])]),
        ])
        let messages = AXNode(role: kAXScrollAreaRole, frame: frame(410, 90, 701, 339), children: [
            AXNode(role: kAXTableRole, frame: frame(410, -2000, 701, 2429), children: [theirs, time, picture, mine]),
        ])
        var children = [
            AXNode(role: kAXStaticTextRole, frame: frame(30, 50, 90, 16), text: "阿里云服务支持"),
            AXNode(role: kAXStaticTextRole, frame: frame(430, 72, 120, 14), text: "归属于 运维组"),
            AXNode(role: kAXStaticTextRole, frame: frame(430, 48, 70, 20), text: "服务告警"),
            list, messages,
        ]
        if input {
            children.append(AXNode(role: kAXTextAreaRole, frame: frame(410, 470, 701, 235), text: draft, editable: true))
        }
        return AXNode(role: kAXWindowRole, frame: frame(0, 0, 1111, 753), children: children)
    }

    @Test func theChatIsReadThroughAccessibility() throws {
        let reading = try #require(DingTalkScreen.read(Self.window(draft: "收到")))
        #expect(reading.title == "服务告警" && reading.draft == "收到")
        #expect(reading.input == Self.frame(410, 470, 701, 235))
        #expect(reading.messages == [
            DingTalkScreen.Message(sender: "告警机器人", fromMe: false, text: "服务副本数为 0\n请及时处理"),
            DingTalkScreen.Message(sender: "", fromMe: true, text: "在看"),
        ])
    }

    @Test func withoutAnInputBoxThereIsNoChat() {
        #expect(DingTalkScreen.read(Self.window(input: false)) == nil)
        #expect(DingTalkScreen.read(AXNode(role: kAXWindowRole, frame: Self.frame(0, 0, 800, 600))) == nil)
    }

    @Test func messagesGoToTheEngineSplitBySender() throws {
        let reading = try #require(DingTalkScreen.read(Self.window()))
        let look = ScreenLook(title: reading.title, draft: "", input: .zero, typing: .zero, anchor: .zero, hint: nil,
                              composer: Pixels.Color(r: 255, g: 255, b: 255),
                              context: DingTalkAssistant.Context.messages(reading.messages))
        let payload = DingTalkAssistant().payload(id: "r1", platformID: BuiltInApp.dingtalk.platformID, look: look)
        let screen = try #require(payload["screen"] as? [String: Any])
        let messages = try #require(screen["messages"] as? [[String: Any]])
        #expect(payload["platform_id"] as? String == "dingtalk" && screen["title"] as? String == "服务告警")
        #expect(messages.map { $0["from_me"] as? Bool } == [false, true])
        #expect(screen["lines"] == nil)
        #expect(DingTalkAssistant().hasContent(look))
    }

    /// When accessibility shows no chat, the window is read off the screen.
    @Test func theScreenIsTheFallback() async throws {
        let window = DingTalkWindow()
        let image = window.canvas.image, pixels = window.canvas.pixels
        let layout = try #require(DingTalkOCR.layout(pixels, scale: Canvas.scale))
        #expect(abs(layout.header.minY / 2 - 40) <= 2 && abs(layout.messages.maxY / 2 - 430) <= 2 && abs(layout.messages.minX / 2 - 400) <= 2)
        let reading = try await offPool { try DingTalkOCR.read(image, pixels: pixels, layout: layout, scale: Canvas.scale) }
        #expect(reading.title == "服务告警" && reading.draft.isEmpty && reading.hint != nil)
        #expect(reading.lines.contains { $0.text.contains("Infra-HK") })
        #expect(!reading.lines.contains { $0.text.contains("钉钉") }, "the watermark is not a message")

        let typed = DingTalkWindow(draft: "马上处理")
        let typedImage = typed.canvas.image, typedPixels = typed.canvas.pixels
        let typedReading = try await offPool { try DingTalkOCR.read(typedImage, pixels: typedPixels, layout: layout, scale: Canvas.scale) }
        #expect(typedReading.draft == "马上处理" && typedReading.hint == nil)
    }
}

struct BuiltInAppTests {
    @Test func eachAppIsFoundByItsBundleIDs() {
        #expect(BuiltInApp.app(bundleID: "com.tencent.xinWeChat") == .wechat)
        #expect(BuiltInApp.app(bundleID: "com.alibaba.DingTalkMac") == .dingtalk)
        #expect(BuiltInApp.app(bundleID: "5ZSL2CJU2T.com.dingtalk.mac") == .dingtalk)
        #expect(BuiltInApp.app(bundleID: "ru.keepcoder.Telegram") == nil)
        #expect(BuiltInApp.app(bundleID: nil) == nil)
        #expect(BuiltInApp.app(bundleID: "com.electron.lark") == nil)
        #expect(BuiltInApp.allCases.map(\.configKey) == ["app.wechat", "app.dingtalk"])
    }

    @Test func faintTextIsAWatermark() {
        let canvas = Canvas(width: 200, height: 60, background: Pixels.Color(r: 255, g: 255, b: 255))
        canvas.draw("水印", at: CGPoint(x: 10, y: 10), size: 16, color: Pixels.Color(r: 235, g: 235, b: 235))
        canvas.draw("正文", at: CGPoint(x: 100, y: 10), size: 16)
        let pixels = canvas.pixels
        let box = { (x: CGFloat) in WeChatScreen.Line(text: "", box: CGRect(x: x * 2, y: 16, width: 70, height: 44)) }
        #expect(ChatOCR.isFaint(box(10), pixels: pixels))
        #expect(!ChatOCR.isFaint(box(100), pixels: pixels))
    }
}
