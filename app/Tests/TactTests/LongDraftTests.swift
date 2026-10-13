import AppKit
import Testing
@testable import Tact

struct LongDraftTests {
    @Test func longSuggestionsShowTheirStartAndLength() {
        let short = String(repeating: "好", count: Overlay.previewLimit)
        #expect(Overlay.preview(short) == (short, nil))
        let long = String(repeating: "这个方案我看过了。", count: 60)
        let (shown, note) = Overlay.preview(long)
        #expect(shown.count == Overlay.previewLimit - 39 && shown.hasSuffix("…") && long.hasPrefix(shown.dropLast()))
        #expect(note == "全文 \(long.count) 字，填入后可在输入框里检查")
    }

    /// WeChat's typing area, as in the window measured: the first line sits
    /// about 14 points below the top, lines are about 20 points apart.
    @Test func aWeChatDraftThatFillsTheBoxMayBeCutOff() {
        let typing = CGRect(x: 0, y: 0, width: 600, height: 81)
        let line = { (row: Int) in
            WeChatScreen.Line(text: "第\(row)行", box: CGRect(x: 10, y: 14 + CGFloat(row) * 20, width: 200, height: 18))
        }
        #expect(!WeChatScreen.draftMayBeClipped([], in: typing))
        #expect(!WeChatScreen.draftMayBeClipped([line(0)], in: typing))
        #expect(!WeChatScreen.draftMayBeClipped([line(0), line(1)], in: typing))
        #expect(WeChatScreen.draftMayBeClipped([line(0), line(1), line(2)], in: typing))
        let scrolled = WeChatScreen.Line(text: "中间一行", box: CGRect(x: 10, y: 2, width: 200, height: 18))
        #expect(WeChatScreen.draftMayBeClipped([scrolled], in: typing))
        let hint = WeChatScreen.Line(text: "按住鼠标 语音输入文字", box: CGRect(x: 10, y: 14, width: 200, height: 18))
        #expect(WeChatScreen.draftLines(from: [hint, line(1)], in: typing) == [line(1)])
    }

    @Test func aTelegramDraftAtTheTopOfItsPanelHasScrolled() {
        let typing = CGRect(x: 0, y: 0, width: 600, height: 50)
        let centred = WeChatScreen.Line(text: "明天见", box: CGRect(x: 10, y: 16, width: 80, height: 18))
        #expect(!TelegramScreen.scrolled([centred], in: typing))
        #expect(!TelegramScreen.scrolled([], in: typing))
        let top = WeChatScreen.Line(text: "第五行", box: CGRect(x: 10, y: 2, width: 80, height: 18))
        #expect(TelegramScreen.scrolled([top, centred], in: typing))
    }
}
