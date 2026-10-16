import AppKit
import Testing
@testable import Tact

@MainActor
struct OverlayPolishTests {
    @Test func secondsAndCancelShowOnlyOnceTheWaitRunsLong() {
        #expect(WorkingStatus.detail(elapsed: 0) == nil)
        #expect(WorkingStatus.detail(elapsed: WorkingStatus.patience - 0.5) == nil)
        #expect(WorkingStatus.detail(elapsed: 8.4)?.contains("8") == true)
        #expect(WorkingStatus.detail(elapsed: 8.4)?.contains("Esc") == true)
        #expect(WorkingStatus.label(.reading) != WorkingStatus.label(.writing))
    }

    @Test func dotsLightOneAfterAnother() {
        let peak = 0.2 * PulsingDots.period
        #expect(PulsingDots.level(at: peak) == 1)
        #expect(PulsingDots.level(at: 0) == PulsingDots.rest)
        #expect(PulsingDots.level(at: 0.9 * PulsingDots.period) == PulsingDots.rest)
        // The next dot lags, so they never peak together.
        #expect(PulsingDots.level(at: peak - PulsingDots.stagger) < 1)
        for step in 0..<100 {
            let level = PulsingDots.level(at: Double(step) * 0.037 - 1)
            #expect(level >= PulsingDots.rest - 1e-9 && level <= 1)
        }
    }

    /// The capsule sits just above the input box at its left edge, where a
    /// rewrite's card appears, whatever the caret: nothing about the chat
    /// app's text decides where it goes.
    @Test func theCapsuleSitsAboveTheInputBoxAtItsLeftEdge() {
        let input = CGRect(x: 400, y: 700, width: 520, height: 60)
        let frame = Overlay.workingFrame(input: input)
        let inset = WorkingCapsule.shadowInset
        #expect(frame.minX + inset == input.minX)
        #expect(frame.maxY - inset == input.minY - 8)
        #expect(frame.width > 120 && frame.height < 70)
    }

    @Test func theCapsuleKeepsItsPlaceAsItsWordsChange() {
        let overlay = Overlay(level: .statusBar)
        let input = CGRect(x: -20000, y: 400, width: 420, height: 60)
        overlay.showWorking(input: input, step: .reading)
        let reading = overlay.snapshot()?.size
        overlay.updateWorking(.writing)
        #expect(overlay.snapshot()?.size == reading)
        overlay.hide()
    }
}
