import AppKit
import Sparkle
import Testing
@testable import Tact

@MainActor
struct UpdatesTests {
    /// `swift run` and the tests have no feed in their Info.plist: no
    /// updater starts, and the About page leaves its card out.
    @Test func aBuildWithoutAFeedHasNoUpdater() {
        let updates = Updates()
        updates.start(bundle: Bundle(for: Updates.self))
        #expect(!updates.isAvailable)
        #expect(!updates.canCheck)
        updates.check()
        #expect(updates.waiting == nil)
    }

    /// Near launch Sparkle shows its own window; later Tact keeps a reminder
    /// rather than open one behind the chat in use.
    @Test func onlyAnUpdateFoundNearLaunchOpensAWindow() {
        let updates = Updates()
        #expect(updates.supportsGentleScheduledUpdateReminders)
        #expect(updates.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true))
        #expect(!updates.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: false))
    }

    @Test func theReminderGoesOnceTheUserLooks() {
        let updates = Updates()
        updates.noticed("0.1.3")
        #expect(updates.waiting == "0.1.3")
        updates.standardUserDriverDidReceiveUserAttention(forUpdate: .empty())
        #expect(updates.waiting == nil)

        updates.noticed("0.1.3")
        updates.standardUserDriverWillFinishUpdateSession()
        #expect(updates.waiting == nil)
    }

    /// The dot sits in the top right corner, inside a clear ring; the rest of
    /// the mark is untouched.
    @Test func aWaitingUpdateDotsTheMenuBarMark() throws {
        let plain = try pixels(MenuBarMark.image(badged: false))
        let badged = MenuBarMark.image(badged: true)
        #expect(badged.isTemplate)
        #expect(badged.size == NSSize(width: 18, height: 18))
        let dotted = try pixels(badged)
        // 2x pixels, origin at the top left: the dot's centre is 3pt in from
        // the top right, the ring 0.75pt beyond its edge.
        #expect(dotted.alpha(x: 30, y: 6) > 0.9, "the dot")
        #expect(dotted.alpha(x: 30, y: 13) < 0.1, "the ring below it")
        #expect(dotted.alpha(x: 23, y: 6) < 0.1, "the ring beside it")
        #expect(dotted.alpha(x: 18, y: 26) == plain.alpha(x: 18, y: 26), "the face as before")
        #expect(MenuBarMark.image(badged: false).accessibilityDescription == "Tact")
    }

    private func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

private extension NSBitmapImageRep {
    func alpha(x: Int, y: Int) -> CGFloat { colorAt(x: x, y: y)?.alphaComponent ?? 0 }
}
