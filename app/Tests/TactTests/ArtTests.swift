import AppKit
import Testing
@testable import Tact

@MainActor
struct ArtTests {
    @Test func shaderCompilesAndDrawsAFrame() throws {
        let renderer = try #require(DitherRenderer.shared)
        let image = try #require(renderer.image(width: 64, height: 40, time: 3, cell: 4, layout: .hero))
        #expect(image.width == 64 && image.height == 40)
    }

    @Test func rendersSnapshots() {
        #expect(Snapshot.render(DitherArtView(layout: .hero), name: "art-hero", size: CGSize(width: 300, height: 620)) != nil)
    }

    @Test func detachedAndHiddenArtStopsDrawing() throws {
        let renderer = try #require(DitherRenderer.shared)
        let view = DitherMTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40), device: renderer.device)
        view.animationEnabled = true
        #expect(view.isPaused)
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        #expect(!view.isPaused)
        view.isHidden = true
        #expect(view.isPaused)
        view.isHidden = false
        #expect(!view.isPaused)
        view.animationEnabled = false
        #expect(view.isPaused)
        view.animationEnabled = true
        #expect(!view.isPaused)
        window.contentView = nil
        #expect(view.isPaused)
    }
}

@MainActor
struct IconTests {
    @Test func iconRendersAt1024PixelsWithTheArtwork() throws {
        #expect(AppIconView.repositoryArtwork != nil, "assets/tact-icon-1024.png is the icon's source")
        let data = try #require(ViewRenderer.png(AppIconView(), size: CGSize(width: 512, height: 512), scale: 2))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(rep.pixelsWide == 1024 && rep.pixelsHigh == 1024)
        // The rounded square sits inside Apple's grid: corners clear, centre opaque.
        #expect((rep.colorAt(x: 4, y: 4)?.alphaComponent ?? 1) < 0.05)
        #expect((rep.colorAt(x: 512, y: 512)?.alphaComponent ?? 0) > 0.99)
        try data.write(to: Snapshot.directory.appendingPathComponent("icon.png"))
    }

    @Test func iconExportRefusesAMissingArtwork() {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png").path
        #expect(!ViewRenderer.exportIcon(to: out, artwork: "/nonexistent/art.png"))
        #expect(!FileManager.default.fileExists(atPath: out))
    }

    /// The menu bar mark comes from assets/menubar at 1x, 2x and 3x.
    @Test func menuBarMarkIsATemplateAtEveryScale() throws {
        let source = try #require(MenuBarMark.repositoryImage(), "assets/menubar holds the menu bar mark")
        #expect(Set(source.representations.map(\.pixelsWide)) == [18, 36, 54])
        let image = MenuBarMark.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let rep = try #require(source.representations.first { $0.pixelsWide == 36 } as? NSBitmapImageRep)
        var opaque = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 } }
        #expect(opaque > 300 && opaque < 36 * 36 - 300, "a shape, neither empty nor a filled square")
        #expect((rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1, "corners stay clear")
        try rep.representation(using: .png, properties: [:])?.write(to: Snapshot.directory.appendingPathComponent("menu-bar-mark.png"))
    }
}
