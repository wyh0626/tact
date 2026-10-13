import CoreGraphics
import Testing
@testable import Tact

struct DoubleTapTests {
    private let ctrl = CGEventFlags.maskControl

    /// Presses and releases ⌃ at the given times; returns whether it fired.
    private func tap(_ d: inout DoubleTapDetector, down: Double, up: Double) -> Bool {
        let fired = d.flagsChanged(ctrl, at: down)
        return d.flagsChanged([], at: up) || fired
    }

    @Test func twoQuickTapsFire() {
        var d = DoubleTapDetector(modifier: ctrl)
        let t0 = tap(&d, down: 0, up: 0.08)
        #expect(!t0)
        let t0_2 = tap(&d, down: 0.2, up: 0.28)
        #expect(t0_2)
    }

    @Test func thirdTapStartsOver() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        let t0_2 = tap(&d, down: 0.2, up: 0.28)
        #expect(t0_2)
        let t0_4 = tap(&d, down: 0.4, up: 0.48)
        #expect(!t0_4)
    }

    @Test func slowSecondTapDoesNotFire() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        let t0_9 = tap(&d, down: 0.9, up: 0.98)
        #expect(!t0_9)
        let t1_1 = tap(&d, down: 1.1, up: 1.18)
        #expect(t1_1, "the slow tap counts as a new first tap")
    }

    @Test func longHoldIsNotATap() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        let t0_15 = tap(&d, down: 0.15, up: 0.8)
        #expect(!t0_15)
    }

    @Test func shortcutBetweenTapsCancels() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        d.otherInput()
        let t0_2 = tap(&d, down: 0.2, up: 0.28)
        #expect(!t0_2)
    }

    @Test func keyWhileHoldingIsNotATap() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        _ = d.flagsChanged(ctrl, at: 0.2)
        d.otherInput() // ⌃C
        let fired = d.flagsChanged([], at: 0.25)
        #expect(!fired)
    }

    @Test func otherModifierJoiningCancels() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        _ = d.flagsChanged(ctrl, at: 0.2)
        _ = d.flagsChanged([ctrl, .maskShift], at: 0.22)
        _ = d.flagsChanged(ctrl, at: 0.24)
        let fired = d.flagsChanged([], at: 0.26)
        #expect(!fired)
    }

    @Test func otherModifierAloneBetweenTapsCancels() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        _ = d.flagsChanged(.maskShift, at: 0.12)
        _ = d.flagsChanged([], at: 0.15)
        let t0_2 = tap(&d, down: 0.2, up: 0.28)
        #expect(!t0_2)
    }

    @Test func capsLockIsIgnored() {
        var d = DoubleTapDetector(modifier: ctrl)
        _ = tap(&d, down: 0, up: 0.08)
        let onPress = d.flagsChanged([ctrl, .maskAlphaShift], at: 0.2)
        let onRelease = d.flagsChanged(.maskAlphaShift, at: 0.28)
        #expect(!onPress)
        #expect(onRelease)
    }
}

struct TriggerSpecTests {
    @Test func parsesDoubleTap() {
        #expect(TriggerSpec.parse("double+ctrl") == .doubleTap(.maskControl, display: "双击 ⌃"))
        #expect(TriggerSpec.parse("Double + Command") == .doubleTap(.maskCommand, display: "双击 ⌘"))
    }

    @Test func combosPassThrough() {
        #expect(TriggerSpec.parse("ctrl+option+space") == .combo("ctrl+option+space"))
    }

    @Test func rejectsBadDoubleTap() {
        #expect(TriggerSpec.parse("double+space") == nil)
        #expect(TriggerSpec.parse("double") == nil)
    }
}
