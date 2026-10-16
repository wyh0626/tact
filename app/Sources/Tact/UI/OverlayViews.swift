import SwiftUI

/// The step a suggestion is at while the user waits, as the working
/// indicator says it.
@MainActor
final class WorkingStatus: ObservableObject {
    enum Step {
        /// Reading the chat window, before anything goes to the model.
        case reading
        case writing
    }

    @Published var step: Step
    let started: Date

    init(step: Step, started: Date) {
        self.step = step
        self.started = started
    }

    /// After this long the indicator adds the seconds so far and how to
    /// cancel: a quick reply stays free of them.
    nonisolated static let patience: TimeInterval = 3

    nonisolated static func label(_ step: Step) -> String {
        switch step {
        case .reading: return L10n.tr("正在读取聊天", "Reading the chat")
        case .writing: return L10n.tr("正在生成", "Writing")
        }
    }

    /// "8 秒 · Esc 取消" once the wait has run `patience`; nil before.
    nonisolated static func detail(elapsed: TimeInterval) -> String? {
        guard elapsed >= patience else { return nil }
        return L10n.tr("\(Int(elapsed)) 秒 · Esc 取消", "\(Int(elapsed))s · Esc to cancel")
    }
}

/// A small capsule above the input box while a suggestion is made: dots
/// lighting in turn, the step under way and, for a long wait, the seconds
/// so far. It sits beside the chat's input box rather than inside it, as
/// Grammarly's button does, so it needs nothing from the chat app's caret,
/// colours or placeholder to look right in any of them.
struct WorkingCapsule: View {
    @ObservedObject var status: WorkingStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room around the capsule for its shadow inside the panel.
    static let shadowInset: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            HStack(spacing: 8) {
                PulsingDots(size: 5, color: Theme.accent, time: reduceMotion ? nil : context.date.timeIntervalSinceReferenceDate)
                Text(WorkingStatus.label(status.step))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                if let detail = WorkingStatus.detail(elapsed: context.date.timeIntervalSince(status.started)) {
                    Text(detail)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.leading, 11)
            .padding(.trailing, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
            .padding(Self.shadowInset)
        }
        // The panel fits the longest it will say; a shorter capsule keeps
        // to the corner nearest the input box.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Three accent dots that brighten one after another, or rest in a fixed
/// fade when the user reduces motion (`time` nil).
struct PulsingDots: View {
    let size: CGFloat
    let color: Color
    let time: TimeInterval?

    var body: some View {
        HStack(spacing: size * 0.75) {
            ForEach(0..<3, id: \.self) { index in
                let level = time.map { Self.level(at: $0 - Double(index) * Self.stagger) } ?? [1, 0.6, 0.3][index]
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .opacity(level)
                    .scaleEffect(0.9 + 0.2 * level)
            }
        }
    }

    /// One dot's pulse lasts most of a period and the next starts a fifth of
    /// a second later, so one is always lit while the work goes on.
    static let period: TimeInterval = 1.2
    static let stagger: TimeInterval = 0.2
    /// The dim level the dots rest at between pulses.
    static let rest = 0.35

    /// A quick rise, a short hold and a slow fall, then rest till the next
    /// period: each dot is lit for a moment, never all at once.
    static func level(at time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let p = phase < 0 ? phase + 1 : phase
        func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
        switch p {
        case ..<0.05: return rest
        case ..<0.15: return rest + (1 - rest) * ease((p - 0.05) / 0.1)
        case ..<0.25: return 1
        case ..<0.65: return 1 - (1 - rest) * ease((p - 0.25) / 0.4)
        default: return rest
        }
    }
}

/// A suggestion that is not ghost text: a rewrite of what was typed, or a
/// reply too long for the input box, in a card above the box.
struct SuggestionCard: View {
    let text: String
    let notes: [String]
    /// Said when the card shows only the start of a long reply.
    let lengthNote: String?
    let keys: [(key: String, action: String)]
    let fontSize: CGFloat
    let maxWidth: CGFloat

    /// Room around the card for its shadow inside the panel.
    static let shadowInset: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.system(size: fontSize + 1))
                .foregroundStyle(Theme.ink)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            if !notes.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5))
                    Text(notes.joined(separator: L10n.tr("；", "; ")))
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
            }
            if let lengthNote {
                Text(lengthNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            HStack(spacing: 14) {
                ForEach(keys, id: \.key) { hint in
                    KeyHint(key: hint.key, action: hint.action)
                }
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(0.13), radius: 14, y: 7)
        .padding(Self.shadowInset)
    }
}

/// A key cap and what pressing it does.
private struct KeyHint: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            Text(action)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}

/// A short status above the input box: what happened, in one or two lines.
struct StatusToast: View {
    let text: String
    let warning: Bool

    static let shadowInset: CGFloat = 14

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(warning ? Theme.warn : Color.secondary)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.07), radius: 1.5, y: 1)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
        .padding(Self.shadowInset)
    }
}
