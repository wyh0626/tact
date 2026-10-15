import AppKit

@main
struct TactApp {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--export-icon"), flag + 1 < arguments.count {
            let artwork = arguments.firstIndex(of: "--artwork").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            exit(ViewRenderer.exportIcon(to: arguments[flag + 1], artwork: artwork) ? 0 : 1)
        }
        if let flag = arguments.firstIndex(of: "--inspect-app"), flag + 2 < arguments.count {
            let screenshot = arguments.firstIndex(of: "--screenshot").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            exit(AppInspector.run(bundleID: arguments[flag + 1], output: arguments[flag + 2], screenshot: screenshot) ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
