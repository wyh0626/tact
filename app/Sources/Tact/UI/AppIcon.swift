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

    /// The mark with a dot in its top right corner while a new version
    /// waits, and in its bottom right corner a ring while a suggestion is
    /// generated or a dot while one waits for its chat. Each is set off by
    /// a clear ring.
    static func image(badged: Bool, activity: SuggestionActivity.Kind = .none) -> NSImage {
        let mark = image()
        guard badged || activity != .none else { return mark }
        let marked = NSImage(size: mark.size, flipped: false) { rect in
            mark.draw(in: rect)
            if badged { dot(NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6), filled: true) }
            if activity != .none { dot(NSRect(x: rect.maxX - 6, y: rect.minY, width: 6, height: 6), filled: activity == .ready) }
            return true
        }
        marked.isTemplate = true
        var description = ["Tact"]
        if badged { description.append(L10n.tr("有新版本", "update available")) }
        switch activity {
        case .generating: description.append(L10n.tr("正在生成建议", "generating a suggestion"))
        case .ready: description.append(L10n.tr("建议已准备好，回到原会话查看", "suggestion ready in its chat"))
        case .none: break
        }
        marked.accessibilityDescription = description.joined(separator: L10n.tr("，", ", "))
        return marked
    }

    private static func dot(_ rect: NSRect, filled: Bool) {
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: rect.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSColor.black.set()
        if filled {
            NSBezierPath(ovalIn: rect).fill()
        } else {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
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
