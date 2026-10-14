import Foundation
import Testing
@testable import Tact

struct WeChatContextTests {
    private func layout(scale: CGFloat = 1) -> WeChatScreen.Layout {
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale)
        }
        return .init(chat: rect(300, 0, 700, 600), header: rect(300, 0, 700, 50),
                     messages: rect(300, 50, 700, 420), input: rect(300, 470, 700, 130),
                     typing: rect(300, 470, 700, 130 - WeChatScreen.controlsHeight),
                     background: .init(r: 250, g: 250, b: 250))
    }

    @Test func onlyCurrentChatTextIsSentWithoutSenderGuesses() throws {
        let area = layout()
        let reading = WeChatScreen.readForModel([
            .init(text: "其他聊天的预览", box: CGRect(x: 100, y: 80, width: 120, height: 16)),
            .init(text: "项目群(5)", box: CGRect(x: 315, y: 21, width: 100, height: 17)),
            .init(text: "王五", box: CGRect(x: 365, y: 60, width: 30, height: 12)),
            .init(text: "12:30", box: CGRect(x: 610, y: 90, width: 40, height: 12)),
            .init(text: "下午能开会吗", box: CGRect(x: 375, y: 120, width: 100, height: 16)),
            .init(text: "我确认一下", box: CGRect(x: 800, y: 150, width: 100, height: 16)),
            .init(text: "别承诺时间", box: CGRect(x: 320, y: 490, width: 100, height: 16)),
        ], layout: area)
        #expect(reading.title == "项目群" && reading.isGroup)
        #expect(reading.draft == "别承诺时间")
        let blocks = reading.rawLines
        #expect(blocks.map(\.text) == ["王五", "12:30", "下午能开会吗", "我确认一下"])
        let payload = WeChatAssistant.payload(id: "r1", reading: reading)
        let screen = try #require(payload["screen"] as? [String: Any])
        #expect(screen["messages"] == nil)
        #expect((screen["lines"] as? [[String: Any]])?.count == 4)
        #expect(payload["input"] as? String == "别承诺时间")
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(!String(decoding: data, as: UTF8.self).contains("其他聊天的预览"))
        #expect(WeChatAssistant.summary(reading).contains(L10n.tr("测试模式未调用 AI", "Test mode did not call AI")))
    }

    @Test func positionsAreIndependentOfPixelScale() throws {
        func read(_ scale: CGFloat) -> WeChatScreen.TextBlock? {
            WeChatScreen.readForModel([
                .init(text: "收到", box: CGRect(x: 370 * scale, y: 92 * scale, width: 140 * scale, height: 21 * scale))
            ], layout: layout(scale: scale)).rawLines.first
        }
        let one = try #require(read(1))
        #expect(one == read(2))
        #expect(one == read(1.5))
        #expect(abs(one.x - 0.1) < 0.000001 && abs(one.y - 0.1) < 0.000001)
    }

    @Test func partiallyVisibleTextIsClippedToTheChatArea() throws {
        let reading = WeChatScreen.readForModel([
            .init(text: "边缘文字", box: CGRect(x: 295, y: 45, width: 40, height: 20)),
        ], layout: layout())
        let block = try #require(reading.rawLines.first)
        #expect(block.x == 0 && block.y == 0)
        #expect(block.width > 0 && block.x + block.width <= 1)
        #expect(block.height > 0 && block.y + block.height <= 1)
    }

    @Test func draftUsesTheFullWidthAndExcludesOnlyKnownControls() {
        let input = layout().input
        let text = WeChatScreen.draft(from: [
            .init(text: "我想确认", box: CGRect(x: 320, y: 490, width: 80, height: 16)),
            .init(text: "这周能否处理完", box: CGRect(x: 800, y: 490, width: 140, height: 16)),
            .init(text: "发送(S)", box: CGRect(x: 920, y: 560, width: 60, height: 16)),
            .init(text: "窗口外文字", box: CGRect(x: 100, y: 490, width: 80, height: 16)),
        ], in: input)
        #expect(text == "我想确认这周能否处理完")
        #expect(WeChatScreen.draft(from: [.init(text: "输入消息...", box: CGRect(x: 320, y: 490, width: 80, height: 16))], in: input).isEmpty)
    }
}
