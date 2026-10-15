import AppKit
import SwiftUI

/// Design tokens: one quiet neutral surface, white grouped cards with
/// hairlines, system type throughout, and a single cobalt accent. State is
/// shown with a coloured dot, never a coloured bar. Colours adapt to light
/// and dark appearance.
enum Theme {
    /// The brand cobalt, fixed for the dithered art and the caret pixels.
    static let accentNS = NSColor(srgbRed: 0.247, green: 0.420, blue: 1.0, alpha: 1)
    static let warnNS = dynamicNS(light: (0.706, 0.325, 0.035), dark: (0.949, 0.710, 0.267))
    static let surfaceNS = dynamicNS(light: (1, 1, 1), dark: (0.137, 0.137, 0.153))
    static let hairlineNS = dynamicNS(light: (0.890, 0.890, 0.910), dark: (0.200, 0.200, 0.224))
    static let inkNS = dynamicNS(light: (0.110, 0.110, 0.129), dark: (0.929, 0.929, 0.945))

    /// The accent for controls: lighter in dark mode so it reads on dark cards.
    static let accent = dynamic(light: (0.247, 0.420, 1.0), dark: (0.561, 0.659, 1.0))
    static let accentSoft = dynamic(light: (0.925, 0.941, 1.0), dark: (0.153, 0.176, 0.290))
    /// Text on an accent-filled control.
    static let onAccent = dynamic(light: (1, 1, 1), dark: (0.067, 0.078, 0.161))
    static let ok = dynamic(light: (0.094, 0.604, 0.345), dark: (0.435, 0.851, 0.608))
    static let warn = Color(nsColor: warnNS)
    static let danger = dynamic(light: (0.839, 0.271, 0.271), dark: (0.949, 0.545, 0.510))

    /// Window background.
    static let canvas = dynamic(light: (0.957, 0.957, 0.965), dark: (0.102, 0.102, 0.118))
    /// Cards and fields.
    static let surface = Color(nsColor: surfaceNS)
    /// An opened row inside a card, a shade off the card itself.
    static let sunken = dynamic(light: (0.976, 0.976, 0.984), dark: (0.118, 0.118, 0.133))
    static let sidebar = dynamic(light: (0.925, 0.925, 0.941), dark: (0.086, 0.086, 0.098))
    /// The selected sidebar row.
    static let selection = dynamic(light: (0.871, 0.871, 0.894), dark: (0.173, 0.173, 0.196))
    static let hairline = Color(nsColor: hairlineNS)
    /// A control's edge: a step darker than a card's hairline so buttons read
    /// as buttons on the canvas and on a card alike.
    static let controlLine = dynamic(light: (0.835, 0.835, 0.859), dark: (0.255, 0.255, 0.282))
    /// Filled wells: code, key caps, pressed buttons.
    static let pill = dynamic(light: (0.945, 0.945, 0.957), dark: (0.176, 0.176, 0.200))
    static let ink = Color(nsColor: inkNS)
    /// Under the pointer: a faint wash of the text colour, on any surface.
    static let hover = Color.primary.opacity(0.05)
    static let pressed = Color.primary.opacity(0.09)
    /// A button's own fill: a tint of the text colour, so it reads on the
    /// canvas and on a card alike without an outline of its own.
    static let fill = Color.primary.opacity(0.06)
    static let fillHover = Color.primary.opacity(0.1)
    static let fillPressed = Color.primary.opacity(0.14)
    /// A text button's colour: quieter than ink, still 4.5:1 on every surface.
    static let quiet = dynamic(light: (0.388, 0.388, 0.420), dark: (0.631, 0.631, 0.667))

    static let cornerRadius: CGFloat = 12

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    private static func dynamicNS(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}

/// How things move. Every state change that moves or reveals something uses
/// one of these, so the app moves with one rhythm; with Reduce Motion on in
/// System Settings they are nil and changes happen at once.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Opening, closing and rearranging: a short spring that barely overshoots.
    static var spring: Animation? { reduced ? nil : .spring(duration: 0.32, bounce: 0.12) }
    /// Hover, press and colour changes.
    static var quick: Animation? { reduced ? nil : .easeOut(duration: 0.14) }
}

/// The app icon as an image. Running from the app bundle uses its icon file,
/// which costs nothing to draw; tests and `swift run` draw the live view.
struct AppIconImage: View {
    var body: some View {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil, let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            AppIconView()
        }
    }
}

/// A page's title and one line about it, with an optional control on the right.
struct PageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.display(20)).foregroundStyle(Theme.ink)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A small label above a section.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Eyebrow(text: title).padding(.horizontal, 4).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Theme.surface))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

/// A hairline between rows of a card, inset to where the text starts.
struct RowDivider: View {
    var inset: CGFloat = 16

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}

/// One line in a card: what it is on the left, the control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    if let detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if divider { RowDivider() }
        }
    }
}

/// A line icon on a soft well. `tint` colours the glyph; without it the
/// glyph is secondary grey, or ink when `emphasized`.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 24
    var tint: Color?
    var emphasized = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Theme.pill)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .regular))
                    .foregroundStyle(tint ?? (emphasized ? Theme.ink : Color.secondary))
            )
            .frame(width: size, height: size)
    }
}

/// A chat tool's mark: the first letter of its name on a soft tile, since
/// plugins don't ship logos.
struct Monogram: View {
    let name: String
    var size: CGFloat = 30
    var muted = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(muted ? Theme.pill : Theme.accentSoft)
            .overlay(
                Text(name.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(muted ? Color.secondary : Theme.accent)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum StatusTone {
    case neutral, ok, warn

    var color: Color {
        switch self {
        case .neutral: return Color.secondary.opacity(0.5)
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        }
    }
}

/// State as a dot and a few words.
struct StatusDot: View {
    let tone: StatusTone
    let text: String
    var lineLimit: Int? = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(tone.color).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: lineLimit == nil)
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent)
                    .brightness(hovering && isEnabled ? 0.05 : 0))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: configuration.isPressed)
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// A filled button without an outline: cards already draw the one border a
/// group needs, and a second ring inside them makes the page heavy.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.fillPressed : hovering && isEnabled ? Theme.fillHover : Theme.fill))
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: configuration.isPressed)
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// A text-only button for secondary actions such as Close or Remove. It
/// darkens under the pointer.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, tint: tint) }

    private struct Styled: View {
        let configuration: Configuration
        let tint: Color?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint ?? (hovering && isEnabled ? Theme.ink : Theme.quiet))
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.4)
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
        }
    }
}

/// A whole row or card that is one button: a faint wash under the pointer
/// and a dip when pressed. The content draws its own shape and padding.
struct RowButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, cornerRadius: cornerRadius) }

    private struct Styled: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? Theme.pressed : hovering && isEnabled ? Theme.hover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onHover { hovering = $0 }
                .animation(Motion.quick, value: hovering)
                .animation(Motion.quick, value: configuration.isPressed)
        }
    }
}

/// A key cap such as ⌃ or Tab, for showing shortcuts.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .frame(minWidth: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.controlLine))
    }
}
