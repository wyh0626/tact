import AppKit
import SwiftUI
import Testing
@testable import Tact

@MainActor
struct GhostWrappingTests {
    private let text = "这个问题我再确认一下，明天把处理结果同步给你。"

    @Test func narrowInputWrapsTheWholeSuggestion() throws {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        let input = CGRect(x: -20000, y: 400, width: 180, height: 100)
        #expect(overlay.showGhost(text, tags: [], caret: nil, input: input, fontSize: 13, background: .white) == .shown)
        let image = try #require(overlay.snapshot())
        #expect(image.size.width <= input.width)
        #expect(image.size.height > 25 && image.size.height <= input.height)
        let scene = VStack(alignment: .leading) {
            Image(nsImage: image)
            Spacer(minLength: 0)
        }.padding(12).frame(width: 204, height: 124).background(Color.white)
        #expect(Snapshot.render(scene, name: "overlay-ghost-wrapped", size: CGSize(width: 204, height: 124)) != nil)
    }

    @Test func fallsBackWhenWrappingExceedsTheInputHeight() {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        let input = CGRect(x: -20000, y: 400, width: 180, height: 24)
        #expect(overlay.showGhost(text, tags: [], caret: nil, input: input, fontSize: 13, background: .white) == .tooTall)
        #expect(!overlay.isVisible)
    }

    @Test func explicitLineBreaksCanStayInline() {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        let input = CGRect(x: -20000, y: 400, width: 240, height: 100)
        #expect(overlay.showGhost("我先确认一下\n稍后同步结果", tags: [], caret: nil, input: input, fontSize: 13, background: .white) == .shown)
    }

    @Test func caretNearTheBottomCannotOverflowTheInput() {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        let input = CGRect(x: -20000, y: 400, width: 180, height: 100)
        let caret = CGRect(x: input.minX + 2, y: input.maxY - 15, width: 1, height: 14)
        #expect(overlay.showGhost(text, tags: [], caret: caret, input: input, fontSize: 13, background: .white) == .tooTall)
    }

    @Test func insufficientWidthUsesABubble() {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        let input = CGRect(x: -20000, y: 400, width: 30, height: 100)
        #expect(overlay.showGhost("收到", tags: [], caret: nil, input: input, fontSize: 13, background: .white) == .tooWide)
    }
}
