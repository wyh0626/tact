import AppKit
import SwiftUI

/// Draws a SwiftUI view into a PNG without showing a window or capturing the
/// screen. Used to export the app icon and to review screens in tests.
@MainActor
enum ViewRenderer {
    static func png<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, dark: Bool = false) -> Data? {
        _ = NSApplication.shared
        let stillBefore = DitherArtView.renderStill
        DitherArtView.renderStill = true
        defer { DitherArtView.renderStill = stillBefore }

        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// `Tact --export-icon <file.png>` writes the 1024-pixel app icon;
    /// scripts/build-app.sh turns it into AppIcon.icns.
    static func exportIcon(to path: String, artwork artworkPath: String? = nil) -> Bool {
        var artwork = AppIconView.repositoryArtwork
        if let artworkPath {
            guard let image = NSImage(contentsOfFile: artworkPath) else {
                FileHandle.standardError.write(Data("读不了图标原图：\(artworkPath)\n".utf8))
                return false
            }
            artwork = image
        }
        guard let data = png(AppIconView(artwork: artwork), size: CGSize(width: 512, height: 512), scale: 2) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("写入图标失败：\(error.localizedDescription)\n".utf8))
            return false
        }
    }
}
