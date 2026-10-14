import AppKit
import SwiftUI

/// The app icon: the Labrador artwork on Apple's macOS icon grid, an
/// 824-point rounded square on a 1024-point canvas with a soft shadow.
struct AppIconView: View {
    var artwork: NSImage? = AppIconView.repositoryArtwork

    /// assets/tact-icon-1024.png, for tests and `swift run`; a built app
    /// shows its icon file instead (see `AppIconImage`). Debug builds only,
    /// so a released binary carries no path from the machine it was built on.
    #if DEBUG
    static let repositoryArtwork = NSImage(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("assets/tact-icon-1024.png"))
    #else
    static let repositoryArtwork: NSImage? = nil
    #endif

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 824 / 1024
            let shape = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().interpolation(.high).scaledToFill()
                } else {
                    Theme.accent
                }
            }
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.black.opacity(0.06), lineWidth: max(1, side * 0.002)))
            .shadow(color: .black.opacity(0.22), radius: side * 0.025, y: side * 0.012)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The menu bar mark: the Labrador's head as a template image, so it
/// follows the menu bar's light and dark appearance. The images live in
/// assets/menubar; a built app carries them as resources.
enum MenuBarMark {
    static let name = "TactMenuBarTemplate"

    static func image() -> NSImage {
        let image = Bundle.main.image(forResource: name) ?? repositoryImage()
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Tact"
        return image
    }

    /// The mark with a dot in its top right corner, set off by a clear ring,
    /// while a new version waits.
    static func image(badged: Bool) -> NSImage {
        let mark = image()
        guard badged else { return mark }
        let badged = NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect)
            let dot = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        badged.isTemplate = true
        badged.accessibilityDescription = L10n.tr("Tact，有新版本", "Tact, update available")
        return badged
    }

    /// The repository's copies at every scale, for tests and `swift run`.
    static func repositoryImage() -> NSImage? {
        #if DEBUG
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/menubar", isDirectory: true)
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for suffix in ["", "@2x", "@3x"] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name + suffix + ".png")),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
        }
        return image.representations.isEmpty ? nil : image
        #else
        return nil
        #endif
    }
}
