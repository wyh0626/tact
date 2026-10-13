import AppKit
import Testing
@testable import Tact

struct WeChatComposerTests {
    private let input = CGRect(x: 300, y: 470, width: 700, height: 130)
    private let textBox = CGRect(x: 316, y: 484, width: 220, height: 18)

    @Test(arguments: ["输入消息...", "按住鼠标 语音输入文字", "|按住鼠标 语音输入文字④发送",
                      "丨按住鼠标语音输入文字", "按住鼠标 说话", "按住鼠标语音输入文字 发送(S)"])
    func emptyComposerHintsAreNotDrafts(_ hint: String) {
        let lines = [WeChatScreen.Line(text: hint, box: textBox)]
        #expect(WeChatScreen.draft(from: lines, in: input).isEmpty)
        #expect(WeChatScreen.draft(from: lines, in: input) == WeChatScreen.draft(from: [], in: input))
    }

    @Test func fragmentedPlaceholderAndCaretStayEmpty() {
        let lines: [WeChatScreen.Line] = [
            .init(text: "|", box: CGRect(x: 315, y: 482, width: 1, height: 22)),
            .init(text: "按住鼠标", box: CGRect(x: 316, y: 484, width: 65, height: 18)),
            .init(text: "语音输入文字", box: CGRect(x: 390, y: 484, width: 100, height: 18)),
            .init(text: "④发送", box: CGRect(x: 920, y: 560, width: 60, height: 18)),
        ]
        #expect(WeChatScreen.draft(from: lines, in: input).isEmpty)
        #expect(WeChatScreen.inputAnchor(from: lines, in: input, scale: 1) == lines[0].box)
    }

    @Test func theHintIsFoundOnlyWhileNothingIsTyped() {
        let hint = WeChatScreen.Line(text: "按住鼠标 语音输入文字", box: textBox)
        #expect(WeChatScreen.placeholder(from: [hint], in: input) == textBox)
        #expect(WeChatScreen.placeholder(from: [hint, .init(text: "|", box: CGRect(x: 315, y: 482, width: 1, height: 22))],
                                         in: input) == textBox)
        #expect(WeChatScreen.placeholder(from: [.init(text: "好的", box: textBox)], in: input) == nil)
        #expect(WeChatScreen.placeholder(from: [], in: input) == nil)
    }

    /// WeChat's hint is longer than a short reply: the ghost covers all of it.
    @Test @MainActor func aShortGhostStillCoversTheWholeHint() throws {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        let typing = CGRect(x: -20000, y: 470, width: 684, height: 74)
        #expect(overlay.showGhost("好", tags: [], caret: CGRect(x: -19984, y: 484, width: 1, height: 18), input: typing,
                                  fontSize: 14, background: .white, cover: 160) == .shown)
        let image = try #require(overlay.snapshot())
        #expect(image.size.width >= 160)
    }

    @Test func ordinaryDraftsKeepUIWordsAndRightHandText() {
        let lines: [WeChatScreen.Line] = [
            .init(text: "按住鼠标语音输入文字这个提示是什么意思？", box: textBox),
            .init(text: "发送", box: CGRect(x: 800, y: 484, width: 40, height: 18)),
            .init(text: "确认后再发送", box: CGRect(x: 316, y: 510, width: 120, height: 18)),
            .init(text: "发送(S)", box: CGRect(x: 920, y: 560, width: 60, height: 18)),
        ]
        #expect(WeChatScreen.draft(from: lines, in: input) == "按住鼠标语音输入文字这个提示是什么意思？发送确认后再发送")
        let anchor = WeChatScreen.inputAnchor(from: lines, in: input, scale: 1)
        #expect(anchor.minX == 436 && anchor.midY == 519)
    }

    @Test(arguments: [CGFloat(1), CGFloat(1.5), CGFloat(2)])
    func loadingUsesTheTypingRowAtEveryPixelScale(_ scale: CGFloat) {
        func scaled(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }
        let area = scaled(input)
        let anchor = WeChatScreen.inputAnchor(from: [.init(text: "按住鼠标 语音输入文字", box: scaled(textBox))],
                                              in: area, scale: scale)
        #expect(anchor.minX / scale == 316 && anchor.midY / scale == 493)
        let blank = WeChatScreen.inputAnchor(from: [], in: area, scale: scale)
        #expect(blank == anchor)
        #expect(anchor.midY < area.midY)
    }

    @Test func testPreviewLabelsOCRAndStillSendsEveryBlock() throws {
        let blocks = (1...12).map { WeChatScreen.TextBlock(text: "文字\($0)", x: 0.1, y: Double($0) / 15, width: 0.2, height: 0.03) }
        let reading = WeChatScreen.Reading(title: "测试会话", isGroup: false, draft: "", rawLines: blocks)
        let summary = WeChatAssistant.summary(reading)
        #expect(summary.contains("聊天区 OCR 原文（末尾 3 / 共 12 段）"))
        #expect(summary.contains("文字10\n文字11\n文字12"))
        #expect(summary.contains("输入框：空") && summary.contains("测试模式未调用 AI"))
        let payload = WeChatAssistant.payload(id: "test", reading: reading)
        let screen = try #require(payload["screen"] as? [String: Any])
        #expect((screen["lines"] as? [[String: Any]])?.count == 12)
    }

    @Test @MainActor func workingDotsFollowTheAnchorAndOffset() {
        let caret = CGRect(x: 316, y: 484, width: 1, height: 18)
        let frame = Overlay.workingFrame(caret: caret, input: input, fontSize: 13, offset: CGPoint(x: 2, y: -1))
        #expect(frame.minX == 321 && frame.midY == 492)
        #expect(frame.maxY < input.midY)
        let fallback = Overlay.workingFrame(caret: nil, input: input, fontSize: 13)
        #expect(fallback.midY == input.midY)
    }

    /// Some apps report the caret of an empty input above the box.
    @Test @MainActor func workingDotsStayOnTheInputWhenTheCaretIsOutsideIt() {
        let oneLine = CGRect(x: 300, y: 560, width: 600, height: 20)
        for caretY in [CGFloat(530), 600] {
            let caret = CGRect(x: 302, y: caretY, width: 1, height: 16)
            let frame = Overlay.workingFrame(caret: caret, input: oneLine, fontSize: 13)
            #expect(frame.midY == oneLine.midY && frame.minX == 305)
        }
        let edge = Overlay.workingFrame(caret: CGRect(x: 302, y: 560, width: 1, height: 2), input: oneLine, fontSize: 13)
        #expect(edge.minY >= oneLine.minY && edge.maxY <= oneLine.maxY)
    }

    /// The overlay steps aside while its window is dragged and comes back
    /// once the window is let go and still; a resize ends it.
    @Test func theOverlayWaitsOutADrag() {
        let window = CGRect(x: 100, y: 80, width: 1000, height: 600)
        let dragged = window.offsetBy(dx: 40, dy: -12)
        let start = Date()
        #expect(Overlay.followStep(from: window, to: window, movedAt: nil, at: start, mouseDown: false) == .stay)
        #expect(Overlay.followStep(from: window, to: dragged, movedAt: nil, at: start, mouseDown: true)
                == .stepAside(CGVector(dx: 40, dy: -12)))
        // Held still mid-drag, or only just let go: still out of the way.
        let later = start.addingTimeInterval(0.5)
        #expect(Overlay.followStep(from: dragged, to: dragged, movedAt: start, at: later, mouseDown: true) == .stay)
        #expect(Overlay.followStep(from: dragged, to: dragged, movedAt: later, at: later.addingTimeInterval(0.05),
                                   mouseDown: false) == .stay)
        #expect(Overlay.followStep(from: dragged, to: dragged, movedAt: start, at: later, mouseDown: false) == .comeBack)
        let resized = CGRect(x: 100, y: 80, width: 900, height: 600)
        #expect(Overlay.followStep(from: window, to: resized, movedAt: nil, at: start, mouseDown: true) == .resized)
    }
}
