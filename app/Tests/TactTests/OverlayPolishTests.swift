import AppKit
import Testing
@testable import Tact

@MainActor
struct OverlayPolishTests {
    @Test func elapsedTimeShowsOnlyOnceItRunsLong() {
        #expect(Overlay.elapsedText(seconds: 0) == nil)
        #expect(Overlay.elapsedText(seconds: Overlay.elapsedAfter - 1) == nil)
        #expect(Overlay.elapsedText(seconds: Overlay.elapsedAfter) == "\(Overlay.elapsedAfter)s")
        #expect(Overlay.elapsedText(seconds: 12) == "12s")
    }

    @Test func workingGrowsAChipWithTheSeconds() {
        let overlay = Overlay(level: .statusBar)
        let input = CGRect(x: 200, y: 400, width: 420, height: 60)
        overlay.showWorking(caret: CGRect(x: 210, y: 410, width: 1, height: 18), input: input, fontSize: 14)
        let before = overlay.snapshot()?.size.width ?? 0
        overlay.showElapsed(at: Date().addingTimeInterval(8))
        let after = overlay.snapshot()
        #expect((after?.size.width ?? 0) > before + 10)
        if let after, let data = after.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) {
            try? data.write(to: Snapshot.directory.appendingPathComponent("overlay-working-elapsed.png"))
        }
        overlay.hide()
    }
}
