import AppKit
import QuartzCore

/// A borderless, click-through panel that floats over the chat tool. It shows the
/// suggestion as grey text right after the caret ("ghost"), as a card above
/// the input box, a working indicator at the caret, or a short status pill.
@MainActor
final class Overlay: NSObject {
    enum ToastKind {
        case info
        case warning
    }

    private let panel: NSPanel
    private let container: NSView
    private let label: NSTextField
    /// Layers drawn for the current mode (working pixels, status marker);
    /// removed whenever the overlay switches mode.
    private var decorations: [CALayer] = []

    init(level: NSWindow.Level) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        container = NSView()
        label = NSTextField(wrappingLabelWithString: "")
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        container.wantsLayer = true
        panel.contentView = container

        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.maximumNumberOfLines = 0
        container.addSubview(label)
    }

    var isVisible: Bool { panel.isVisible }

    /// Accessibility rects have their origin at the top-left of the primary
    /// screen; AppKit windows use the bottom-left.
    static func cocoaRect(fromAX r: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - Ghost text

    enum GhostResult: Equatable {
        case shown
        case tooWide
        case tooTall
    }

    /// The input's placeholder ("输入消息...") sits where the ghost goes; an
    /// opaque strip at least this wide hides it behind short suggestions.
    private static let placeholderCover: CGFloat = 120

    /// Grey text after the caret, with short warning tags before the ⇥ hint.
    /// `background` is the input's own colour, painted under the text to hide
    /// the placeholder, at least `cover` wide when the placeholder's width is
    /// known. Wraps within the input before falling back to a card; the full
    /// suggestion must fit, without clipping or truncation.
    func showGhost(_ text: String, tags: [String], caret: CGRect?, input: CGRect, fontSize: CGFloat,
                   offset: CGPoint = .zero, background: NSColor?, cover: CGFloat? = nil) -> GhostResult {
        let body = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
        let hint = (tags.isEmpty ? "" : "  ⚠︎" + tags.joined(separator: " · ")) + "  ⇥"
        body.append(NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: max(9, fontSize - 2)),
            .foregroundColor: tags.isEmpty ? NSColor.tertiaryLabelColor : Theme.warnNS,
        ]))
        // NSTextField draws its text about 2pt in from the frame edge.
        let startX = max(input.minX, (caret?.minX ?? (input.minX + 2)) - 1 + offset.x)
        let available = input.maxX - startX - 8
        guard available >= fontSize * 3 else { return .tooWide }

        label.attributedStringValue = body
        label.preferredMaxLayoutWidth = available - 4
        let fit = label.sizeThatFits(NSSize(width: available - 4, height: .greatestFiniteMagnitude))
        let height = ceil(fit.height) + 2
        let singleLineHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: fontSize))) + 4
        let proposedY = height <= singleLineHeight
            ? (caret?.midY ?? input.midY) - height / 2 + offset.y
            : (caret?.minY ?? input.minY + 1) + offset.y
        let startY = max(input.minY + 1, proposedY)
        guard startY + height <= input.maxY - 1 else { return .tooTall }

        reset()
        var width = min(available, ceil(fit.width) + 4)
        if background != nil { width = min(max(width, cover ?? Self.placeholderCover), available) }
        container.layer?.backgroundColor = background?.cgColor
        label.attributedStringValue = body
        place(CGRect(x: startX, y: startY, width: width, height: height), shadow: false)
        label.frame = container.bounds
        return .shown
    }

    // MARK: - Working

    /// While a suggestion is being written: a short row of accent pixels at
    /// the caret, pulsing left to right where the ghost text will appear.
    func showWorking(caret: CGRect?, input: CGRect, fontSize: CGFloat, offset: CGPoint = .zero) {
        reset()
        label.isHidden = true
        let count = 6
        let pixel = max(3, (fontSize * 0.26).rounded())
        let gap = (pixel * 0.75).rounded()
        let height = max(pixel * 3, fontSize + 4)
        place(Self.workingFrame(caret: caret, input: input, fontSize: fontSize, offset: offset), shadow: false)

        // At rest the pixels fade out to the right like the ghost text in the
        // app icon; the pulse runs over that unless the user reduces motion.
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = CACurrentMediaTime()
        for index in 0..<count {
            let dot = CALayer()
            dot.backgroundColor = Theme.accentNS.cgColor
            dot.frame = CGRect(x: CGFloat(index) * (pixel + gap), y: (height - pixel) / 2, width: pixel, height: pixel)
            let rest = Float(1 - 0.8 * Double(index) / Double(count - 1))
            dot.opacity = rest
            if animate {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = rest * 0.2
                pulse.toValue = 1
                pulse.duration = 0.42
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.beginTime = start + Double(index) * 0.09
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(pulse, forKey: "pulse")
            }
            container.layer?.addSublayer(dot)
            decorations.append(dot)
        }
    }

    /// On the caret's row. Some apps report the caret of an empty input
    /// above the box; then the box's middle is the row, as
    /// it is for a one-line input.
    static func workingFrame(caret: CGRect?, input: CGRect, fontSize: CGFloat, offset: CGPoint = .zero) -> CGRect {
        let pixel = max(3, (fontSize * 0.26).rounded())
        let gap = (pixel * 0.75).rounded()
        let width = 6 * pixel + 5 * gap
        let height = max(pixel * 3, fontSize + 4)
        let row = caret.map(\.midY).flatMap { input.minY...input.maxY ~= $0 ? $0 : nil } ?? input.midY
        var y = row - height / 2 + offset.y
        if height <= input.height - 2 { y = min(max(y, input.minY + 1), input.maxY - 1 - height) }
        return CGRect(x: (caret?.minX ?? (input.minX + 2)) + 3 + offset.x, y: y, width: width, height: height)
    }

    // MARK: - Card

    /// Past this many characters a card shows the start: it cannot scroll,
    /// and the whole text can be read in the input box once filled in.
    nonisolated static let previewLimit = 280

    nonisolated static func preview(_ text: String) -> (shown: String, note: String?) {
        guard text.count > previewLimit else { return (text, nil) }
        return (String(text.prefix(previewLimit - 40)) + "…", "全文 \(text.count) 字，填入后可在输入框里检查")
    }

    /// A suggestion that cannot be ghost text (a rewrite of what was typed,
    /// or too long for one line): a paper card above the input. `footer`
    /// replaces the usual keys line.
    func showBubble(_ text: String, notes: [String], input: CGRect, fontSize: CGFloat, rewrite: Bool, footer: String? = nil) {
        reset()
        let (shown, length) = Self.preview(text)
        let body = NSMutableAttributedString(string: shown, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize + 0.5),
            .foregroundColor: Theme.inkNS,
            .paragraphStyle: Self.lineSpacing(3),
        ])
        if !notes.isEmpty {
            body.append(NSAttributedString(string: "\n⚠︎ " + notes.joined(separator: "；"), attributes: [
                .font: NSFont.systemFont(ofSize: max(10, fontSize - 2)),
                .foregroundColor: Theme.warnNS,
                .paragraphStyle: Self.spacingBefore(6),
            ]))
        }
        if let length {
            body.append(NSAttributedString(string: "\n" + length, attributes: [
                .font: NSFont.systemFont(ofSize: max(10, fontSize - 2)),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: Self.spacingBefore(6),
            ]))
        }
        let keys = footer ?? (rewrite ? "TAB 替换输入框  ·  ESC 取消" : "TAB 填入  ·  ESC 取消")
        body.append(NSAttributedString(string: "\n" + keys, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .kern: 0.6,
            .paragraphStyle: Self.spacingBefore(8),
        ]))
        let frame = layout(body, maxWidth: min(max(input.width, 280), 560), padX: 14, padY: 11, leading: 0, above: input)
        paint { layer in
            layer.backgroundColor = Theme.surfaceNS.cgColor
            layer.borderColor = Theme.hairlineNS.cgColor
            layer.borderWidth = 1
            layer.cornerRadius = 10
        }
        place(frame, shadow: true)
    }

    // MARK: - Status

    /// A short status above the input box: an ink pill with a small square
    /// marker, amber for problems. nil duration keeps it until hidden.
    func showToast(_ text: String, input: CGRect, duration: TimeInterval?, kind: ToastKind = .info) {
        reset()
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let body = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: Self.lineSpacing(2),
        ])
        let marker: CGFloat = 6
        let leading = marker + 8
        let frame = layout(body, maxWidth: 460, padX: 11, padY: 7, leading: leading, above: input)
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.94).cgColor
        container.layer?.cornerRadius = 8
        place(frame, shadow: true)

        let square = CALayer()
        square.backgroundColor = kind == .warning
            ? NSColor(srgbRed: 0.96, green: 0.66, blue: 0.36, alpha: 1).cgColor
            : NSColor(white: 1, alpha: 0.5).cgColor
        // Centred on the first line (layer origin is bottom-left).
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        square.frame = CGRect(x: 11, y: frame.height - 7 - lineHeight / 2 - marker / 2, width: marker, height: marker)
        container.layer?.addSublayer(square)
        decorations.append(square)

        if let duration {
            perform(#selector(hideNow), with: nil, afterDelay: duration)
        }
    }

    func hide() {
        cancelAutoHide()
        panel.orderOut(nil)
    }

    /// What the overlay currently shows, as an image, for reviewing its look
    /// without capturing the screen.
    func snapshot(scale: CGFloat = 2) -> NSImage? {
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        guard let layer = container.layer else { return nil }
        let size = container.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        context.cgContext.scaleBy(x: scale, y: scale)
        // The layer tree holds backgrounds and pixels; the label draws its
        // text itself, so it is drawn on top separately.
        layer.render(in: context.cgContext)
        if !label.isHidden, let text = label.bitmapImageRepForCachingDisplay(in: label.bounds) {
            label.cacheDisplay(in: label.bounds, to: text)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            text.draw(in: label.frame)
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Helpers

    @objc private func hideNow() {
        panel.orderOut(nil)
    }

    private func cancelAutoHide() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideNow), object: nil)
    }

    /// Clears what the previous mode drew.
    private func reset() {
        cancelAutoHide()
        decorations.forEach { $0.removeFromSuperlayer() }
        decorations.removeAll()
        label.isHidden = false
        guard let layer = container.layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.borderWidth = 0
        layer.cornerRadius = 0
    }

    /// Sizes the label for `body` and returns the panel frame above `input`.
    private func layout(_ body: NSAttributedString, maxWidth: CGFloat, padX: CGFloat, padY: CGFloat,
                        leading: CGFloat, above input: CGRect) -> CGRect {
        let textWidth = maxWidth - padX * 2 - leading
        label.attributedStringValue = body
        label.preferredMaxLayoutWidth = textWidth
        let fit = label.sizeThatFits(NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
        let width = ceil(min(fit.width, textWidth)) + padX * 2 + leading
        let height = ceil(fit.height) + padY * 2
        label.frame = NSRect(x: padX + leading, y: padY, width: width - padX * 2 - leading, height: height - padY * 2)
        return CGRect(x: input.minX, y: input.minY - height - 8, width: width, height: height)
    }

    /// Positions the panel (accessibility coordinates) and shows it.
    private func place(_ ax: CGRect, shadow: Bool) {
        panel.hasShadow = shadow
        panel.setFrame(Self.cocoaRect(fromAX: ax), display: false)
        container.frame = NSRect(x: 0, y: 0, width: ax.width, height: ax.height)
        panel.orderFrontRegardless()
    }

    /// Dynamic colours resolve against the panel's appearance.
    private func paint(_ body: (CALayer) -> Void) {
        guard let layer = container.layer else { return }
        container.effectiveAppearance.performAsCurrentDrawingAppearance { body(layer) }
    }

    private static func lineSpacing(_ spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = spacing
        return style
    }

    private static func spacingBefore(_ spacing: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacing
        return style
    }
}
