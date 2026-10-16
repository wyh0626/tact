import AppKit
import SwiftUI

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
    /// The SwiftUI content of the working indicator or the card.
    private var hosted: NSView?
    /// What the working indicator says while it shows.
    private var workingStatus: WorkingStatus?

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

    /// While a suggestion is being made: a capsule above the input box, at
    /// its left edge where a rewrite's card appears. `started` keeps the
    /// seconds counting from the hotkey when it moves or changes step.
    func showWorking(input: CGRect, step: WorkingStatus.Step = .writing, started: Date = Date()) {
        reset()
        label.isHidden = true
        let status = WorkingStatus(step: step, started: started)
        workingStatus = status
        host(WorkingCapsule(status: status), in: Self.onScreen(Self.workingFrame(input: input)))
    }

    /// The step the shown working capsule says, without moving it.
    func updateWorking(_ step: WorkingStatus.Step) {
        workingStatus?.step = step
    }

    /// The panel for the capsule at its longest, its bottom-left corner the
    /// capsule's own, 8 points above the input box.
    static func workingFrame(input: CGRect) -> CGRect {
        let longest = WorkingStatus(step: .reading, started: Date().addingTimeInterval(-99))
        let size = NSHostingView(rootView: LocalizedContent { WorkingCapsule(status: longest) }).fittingSize
        let inset = WorkingCapsule.shadowInset
        return CGRect(x: input.minX - inset, y: input.minY - size.height + inset - 8,
                      width: size.width, height: size.height)
    }

    // MARK: - Card

    /// Past this many characters a card shows the start: it cannot scroll,
    /// and the whole text can be read in the input box once filled in.
    nonisolated static let previewLimit = 280

    nonisolated static func preview(_ text: String) -> (shown: String, note: String?) {
        guard text.count > previewLimit else { return (text, nil) }
        return (String(text.prefix(previewLimit - 40)) + "…", L10n.tr("全文 \(text.count) 字，填入后可在输入框里检查", "\(text.count) characters in total; review the full text in the input after accepting"))
    }

    /// A suggestion that cannot be ghost text (a rewrite of what was typed,
    /// or too long for the input box): a card above the input. `copyOnly`
    /// is for a draft that may not have been read whole: Tab then copies.
    func showBubble(_ text: String, notes: [String], input: CGRect, fontSize: CGFloat, rewrite: Bool, copyOnly: Bool = false) {
        reset()
        label.isHidden = true
        let (shown, length) = Self.preview(text)
        let remarks = [length, copyOnly ? L10n.tr("草稿可能没读全，按 Tab 只复制，不替换", "The draft may not have been read in full: Tab copies instead of replacing") : nil]
        let apply = copyOnly ? L10n.tr("复制", "Copy") : rewrite ? L10n.tr("替换输入框", "Replace input") : L10n.tr("填入", "Apply")
        let remark = remarks.compactMap { $0 }.joined(separator: "\n")
        let card = SuggestionCard(text: shown, notes: notes, lengthNote: remark.isEmpty ? nil : remark,
                                  keys: [("Tab", apply), ("Esc", L10n.tr("取消", "Cancel"))],
                                  fontSize: fontSize, maxWidth: min(max(input.width, 280), 520))
        let size = NSHostingView(rootView: LocalizedContent { card }).fittingSize
        let inset = SuggestionCard.shadowInset
        // The card's top-left above the input box; the panel adds room for the shadow.
        let cardFrame = CGRect(x: input.minX, y: input.minY - (size.height - 2 * inset) - 8,
                               width: size.width - 2 * inset, height: size.height - 2 * inset)
        host(card, in: Self.onScreen(cardFrame.insetBy(dx: -inset, dy: -inset)))
    }

    /// `frame` (accessibility coordinates) moved inside the visible area of
    /// the screen it is on, so a card near an edge is not cut off.
    static func onScreen(_ frame: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let visible = NSScreen.screens.map { screen -> CGRect in
            let f = screen.visibleFrame
            return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        }
        guard let screen = visible.first(where: { $0.intersects(frame) }) else { return frame }
        var fitted = frame
        fitted.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width))
        fitted.origin.y = max(frame.minY, screen.minY)
        return fitted
    }

    /// Shows `view` filling a panel at `frame` (accessibility coordinates).
    private func host<Content: View>(_ view: Content, in frame: CGRect) {
        let hosting = NSHostingView(rootView: LocalizedContent { view })
        place(frame, shadow: false)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        hosted = hosting
    }

    // MARK: - Status

    /// A short status above the input box, on a card like the suggestion's,
    /// with an amber sign for problems. nil duration keeps it until hidden.
    func showToast(_ text: String, input: CGRect, duration: TimeInterval?, kind: ToastKind = .info) {
        reset()
        label.isHidden = true
        let toast = StatusToast(text: text, warning: kind == .warning)
        let size = NSHostingView(rootView: LocalizedContent { toast }).fittingSize
        let inset = StatusToast.shadowInset
        let frame = CGRect(x: input.minX - inset, y: input.minY - (size.height - 2 * inset) - 8 - inset,
                           width: size.width, height: size.height)
        host(toast, in: Self.onScreen(frame))
        if let duration {
            perform(#selector(hideNow), with: nil, afterDelay: duration)
        }
    }

    func hide() {
        cancelAutoHide()
        stopFollowing()
        panel.orderOut(nil)
    }

    // MARK: - Following a window

    /// Keeps what is shown on the window of `pid` at `frame`. While the
    /// window is dragged the overlay steps aside: another app's window
    /// cannot carry it, and trailing a frame behind looks broken. It comes
    /// back in place once the window is let go and still, as input method
    /// candidates do. A resize hides it for good and runs `resized`; hiding
    /// ends the following.
    func follow(pid: pid_t, frame: CGRect, resized: (() -> Void)? = nil) {
        stopFollowing()
        guard let id = Self.windowID(pid: pid, frame: frame) else { return }
        followed = Followed(id: id, frame: frame, resized: resized)
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followTick() }
        }
    }

    private struct Followed {
        let id: CGWindowID
        var frame: CGRect
        let resized: (() -> Void)?
        /// Set while the overlay is out of the way of a moving window.
        var movedAt: Date?
    }

    private var followTimer: Timer?
    private var followed: Followed?

    enum FollowStep: Equatable {
        case stay
        /// The window moved by this much: hide, and shift to match.
        case stepAside(CGVector)
        /// The window was let go and is still: show again.
        case comeBack
        case resized
    }

    nonisolated static func followStep(from frame: CGRect, to now: CGRect, movedAt: Date?, at time: Date,
                                       mouseDown: Bool) -> FollowStep {
        if now != frame {
            guard now.size == frame.size else { return .resized }
            return .stepAside(CGVector(dx: now.minX - frame.minX, dy: now.minY - frame.minY))
        }
        if let movedAt, time.timeIntervalSince(movedAt) > 0.12, !mouseDown { return .comeBack }
        return .stay
    }

    private func followTick() {
        // The window server knows where a window is at every frame of a
        // drag, sooner than the app does.
        guard var target = followed, panel.isVisible || target.movedAt != nil,
              let now = Self.bounds(of: target.id) else {
            stopFollowing()
            return
        }
        let time = Date()
        switch Self.followStep(from: target.frame, to: now, movedAt: target.movedAt, at: time,
                               mouseDown: NSEvent.pressedMouseButtons & 1 != 0) {
        case .stay:
            break
        case .stepAside(let delta):
            panel.orderOut(nil)
            // Window bounds share the accessibility coordinates: y runs down.
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.dx, y: panel.frame.minY - delta.dy))
            target.frame = now
            target.movedAt = time
            followed = target
        case .comeBack:
            followed?.movedAt = nil
            panel.orderFrontRegardless()
        case .resized:
            hide()
            target.resized?()
        }
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        followed = nil
    }

    private static func windowID(pid: pid_t, frame: CGRect) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let match = windows.first { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = bounds(info) else { return false }
            return abs(bounds.minX - frame.minX) < 2 && abs(bounds.minY - frame.minY) < 2
                && abs(bounds.width - frame.width) < 2 && abs(bounds.height - frame.height) < 2
        }
        return match?[kCGWindowNumber as String] as? CGWindowID
    }

    private static func bounds(of id: CGWindowID) -> CGRect? {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first.flatMap(bounds)
    }

    private static func bounds(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }

    /// What the overlay currently shows, as an image, for reviewing its look
    /// without capturing the screen.
    func snapshot(scale: CGFloat = 2) -> NSImage? {
        if let hosted {
            hosted.layoutSubtreeIfNeeded()
            guard let rep = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else { return nil }
            hosted.cacheDisplay(in: hosted.bounds, to: rep)
            let image = NSImage(size: hosted.bounds.size)
            image.addRepresentation(rep)
            return image
        }
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
        stopFollowing()
        panel.orderOut(nil)
    }

    private func cancelAutoHide() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideNow), object: nil)
    }

    /// Clears what the previous mode drew.
    private func reset() {
        cancelAutoHide()
        hosted?.removeFromSuperview()
        hosted = nil
        workingStatus = nil
        label.isHidden = false
        container.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Positions the panel (accessibility coordinates) and shows it.
    private func place(_ ax: CGRect, shadow: Bool) {
        panel.hasShadow = shadow
        panel.setFrame(Self.cocoaRect(fromAX: ax), display: false)
        container.frame = NSRect(x: 0, y: 0, width: ax.width, height: ax.height)
        panel.orderFrontRegardless()
    }
}
