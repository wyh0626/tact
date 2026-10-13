import CoreGraphics

/// Recognizes a modifier key tapped twice on its own, like double ⌃. A tap is
/// a press and release of only that modifier, held briefly, with no other key
/// or click during it; a second tap soon after the first fires. Firing on the
/// release means holding ⌃ for a shortcut like ⌃C never counts.
struct DoubleTapDetector {
    let modifier: CGEventFlags
    var maxHold: Double = 0.35
    var maxGap: Double = 0.45

    private var downAt: Double?
    private var tainted = false
    private var lastTapAt: Double?

    static let tracked: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]

    init(modifier: CGEventFlags) {
        self.modifier = modifier
    }

    /// Feed every flagsChanged event; returns true on the second tap.
    mutating func flagsChanged(_ flags: CGEventFlags, at time: Double) -> Bool {
        let held = flags.intersection(Self.tracked)
        if held == modifier {
            if downAt == nil {
                downAt = time
                tainted = false
            }
            return false
        }
        if held.isEmpty, let start = downAt {
            downAt = nil
            guard !tainted, time - start <= maxHold else {
                lastTapAt = nil
                return false
            }
            if let last = lastTapAt, time - last <= maxGap {
                lastTapAt = nil
                return true
            }
            lastTapAt = time
            return false
        }
        // Another modifier joined in or was pressed on its own.
        if downAt != nil { tainted = true }
        lastTapAt = nil
        return false
    }

    /// Any key press or click between or during the taps cancels them.
    mutating func otherInput() {
        if downAt != nil { tainted = true }
        lastTapAt = nil
    }
}

enum TriggerSpec: Equatable {
    case combo(String)
    case doubleTap(CGEventFlags, display: String)

    /// "double+ctrl" (also cmd, option, shift) is a double tap; anything else
    /// is a Carbon key combination such as "ctrl+option+space".
    static func parse(_ spec: String) -> TriggerSpec? {
        let parts = spec.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "double" else { return .combo(spec) }
        guard parts.count == 2 else { return nil }
        switch parts[1] {
        case "ctrl", "control", "⌃": return .doubleTap(.maskControl, display: "双击 ⌃")
        case "cmd", "command", "⌘": return .doubleTap(.maskCommand, display: "双击 ⌘")
        case "opt", "option", "alt", "⌥": return .doubleTap(.maskAlternate, display: "双击 ⌥")
        case "shift", "⇧": return .doubleTap(.maskShift, display: "双击 ⇧")
        default: return nil
        }
    }
}
