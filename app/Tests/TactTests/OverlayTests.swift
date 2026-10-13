import AppKit
import SwiftUI
import Testing
@testable import Tact

/// Renders each overlay mode over a mock chat input. The panel is placed far
/// off screen so nothing flashes on the user's display.
@MainActor
struct OverlayTests {
    private let input = CGRect(x: -20000, y: 400, width: 460, height: 34)

    private func scene(_ image: NSImage?, dark: Bool, aboveInput: Bool) -> some View {
        let ink = dark ? Color(white: 0.92) : Color(white: 0.12)
        return ZStack(alignment: .bottomLeading) {
            (dark ? Color(white: 0.12) : Color(white: 0.96))
            VStack(alignment: .leading, spacing: 8) {
                if aboveInput, let image { Image(nsImage: image) }
                HStack(spacing: 0) {
                    Text("|").font(.system(size: 13)).foregroundStyle(ink.opacity(0.6))
                    if !aboveInput, let image { Image(nsImage: image) }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(width: 460, height: 34)
                .background(dark ? Color(white: 0.18) : .white)
            }
            .padding(20)
        }
        .frame(width: 520, height: aboveInput ? 190 : 80)
    }

    private func render(_ name: String, aboveInput: Bool, dark: Bool = false, _ show: (Overlay) -> Void) -> Bool {
        let overlay = Overlay(level: .statusBar)
        defer { overlay.hide() }
        show(overlay)
        guard let image = overlay.snapshot() else { return false }
        return Snapshot.render(scene(image, dark: dark, aboveInput: aboveInput), name: name,
                               size: CGSize(width: 520, height: aboveInput ? 190 : 80), dark: dark) != nil
    }

    @Test func workingIndicator() {
        #expect(render("overlay-working", aboveInput: false) { $0.showWorking(caret: nil, input: input, fontSize: 13) })
    }

    @Test func toasts() {
        #expect(render("overlay-toast-info", aboveInput: true) {
            $0.showToast("这次不建议", input: input, duration: nil)
        })
        #expect(render("overlay-toast-warning", aboveInput: true, dark: true) {
            $0.showToast("没认出当前会话（识别到「张扬乐 Erik Zhang」）", input: input, duration: nil, kind: .warning)
        })
    }

    @Test func card() {
        #expect(render("overlay-card", aboveInput: true) {
            $0.showBubble("这个还卡在 AUDIT 的单子，你那边能手动处理吗？我这边先把日志整理好发你",
                          notes: ["含承诺，发出前确认"], input: input, fontSize: 13, rewrite: true)
        })
    }
}
