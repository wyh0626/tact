import CoreGraphics
import Testing
@testable import Tact

struct WeChatCropTests {
    private func window(scale: CGFloat, infoPanel: Bool, ambiguous: Bool = false, dark: Bool = false) throws -> Pixels {
        let size = CGSize(width: infoPanel ? 1000 : 800, height: 600)
        let context = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func fill(_ rect: CGRect, grey: CGFloat) {
            context.setFillColor(CGColor(gray: grey, alpha: 1))
            context.fill(CGRect(x: rect.minX * scale, y: (size.height - rect.maxY) * scale,
                                width: rect.width * scale, height: rect.height * scale))
        }
        let background: CGFloat = dark ? 0.12 : 0.98
        let separator: CGFloat = dark ? 0.3 : 0.75
        fill(CGRect(origin: .zero, size: size), grey: background)
        for x: CGFloat in infoPanel ? [60, 460, 740] : [60, 460] {
            fill(CGRect(x: x, y: 0, width: 1 / scale, height: size.height), grey: separator)
        }
        fill(CGRect(x: 460, y: 470, width: infoPanel ? 280 : 340, height: 1 / scale), grey: separator)
        if infoPanel {
            for y: CGFloat in [120, 250, 440] {
                fill(CGRect(x: 740, y: y, width: 260, height: 1 / scale), grey: separator)
            }
        }
        if ambiguous {
            fill(CGRect(x: 60, y: 470, width: 400, height: 1 / scale), grey: separator)
        }
        let image = try #require(context.makeImage())
        return try #require(Pixels(image))
    }

    @Test func aNarrowChatIsNotConfusedWithTheWiderConversationList() throws {
        for scale: CGFloat in [1, 1.5, 2] {
            let pixels = try window(scale: scale, infoPanel: false)
            let layout = try #require(WeChatScreen.layout(pixels, scale: scale))
            #expect(abs(layout.chat.minX / scale - 460) <= 2)
            #expect(abs(layout.chat.maxX / scale - 800) <= 2)
        }
    }

    @Test func infoPanelSectionsAreExcludedInBothThemes() throws {
        for dark in [false, true] {
            let pixels = try window(scale: 2, infoPanel: true, dark: dark)
            let layout = try #require(WeChatScreen.layout(pixels, scale: 2))
            #expect(abs(layout.chat.minX / 2 - 460) <= 2)
            #expect(abs(layout.chat.maxX / 2 - 740) <= 2)
        }
    }

    @Test func anAmbiguousLayoutIsNotSentToTheModel() throws {
        let pixels = try window(scale: 2, infoPanel: false, ambiguous: true)
        #expect(WeChatScreen.layout(pixels, scale: 2) == nil)
    }
}
