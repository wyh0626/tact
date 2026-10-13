import Testing
@testable import Tact

struct TextUtilTests {
    /// Two reads of the same window: OCR may change punctuation and case.
    @Test func readsOfAnUnchangedChatAgree() {
        #expect(TextUtil.change(from: ("小林", "同意，用西语"), to: ("小林", "同意,用西语")) == nil)
        #expect(TextUtil.change(from: ("Ann", "OK"), to: ("Ann", "ok ")) == nil)
    }

    @Test func anEditOrAnotherChatIsAChange() throws {
        let typed = try #require(TextUtil.change(from: ("小林", "同意，用西语"), to: ("小林", "同意，用西语吧")))
        #expect(typed.contains("5 → 6 字") && typed.contains("第 6 个字起：无 → 汉字"))
        #expect(!typed.contains("西语"), "the log never carries the text")
        let chat = try #require(TextUtil.change(from: ("小林", "好"), to: ("小王", "好")))
        #expect(chat == "会话名和刚才读到的不同（2 → 2 字，第 2 个字起：汉字 → 汉字）")
        #expect(TextUtil.change(from: ("小林", ""), to: ("小林", "ok"))?.contains("0 → 2 字") == true)
    }
}
