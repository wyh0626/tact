import AppKit

/// Tact opened straight from its disk image: permissions and launch at login
/// follow the app's place, and a second copy opened later from Applications
/// fails to launch while this one runs. It offers to move itself first.
@MainActor
enum Relocation {
    enum Place: Equatable {
        case installed
        /// On a read-only volume, a mounted disk image: it can copy itself.
        case diskImage(volume: String)
        /// macOS runs a quarantined app from a hidden copy until it is moved;
        /// the original is out of reach, so the user drags it.
        case translocated
    }

    nonisolated static func place(of bundlePath: String, readOnly: Bool) -> Place {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        guard readOnly else { return .installed }
        let parts = bundlePath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return .installed }
        return .diskImage(volume: "/Volumes/" + parts[1])
    }

    /// Applications when it can be written, as for an admin; else the
    /// user's own Applications folder.
    nonisolated static func destination(appName: String, systemWritable: Bool, home: URL) -> URL {
        let folder = systemWritable ? URL(fileURLWithPath: "/Applications", isDirectory: true)
            : home.appendingPathComponent("Applications", isDirectory: true)
        return folder.appendingPathComponent(appName, isDirectory: true)
    }

    /// Asks before anything else starts. True when this copy is quitting so
    /// the moved one can open.
    static func offerMove() -> Bool {
        let bundle = Bundle.main.bundleURL
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let place = place(of: bundle.path, readOnly: readOnly)
        guard place != .installed else { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.tr("把 Tact 移到「应用程序」文件夹", "Move Tact to the Applications folder")
        alert.informativeText = L10n.tr(
            "Tact 现在是从安装包里直接打开的。放进「应用程序」后，系统授权和开机启动才会一直有效，推出安装包后也还能用。",
            "Tact is running straight from its disk image. In Applications, its permissions and launch at login keep working, and it stays after the disk image is ejected.")
        switch place {
        case .diskImage(let volume):
            alert.addButton(withTitle: L10n.tr("移到「应用程序」", "Move to Applications"))
            alert.addButton(withTitle: L10n.tr("暂不", "Not now"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            return move(bundle, unmounting: volume)
        case .translocated:
            alert.informativeText += "\n\n" + L10n.tr("请退出 Tact，把它拖进「应用程序」后再从那里打开。",
                                                      "Quit Tact, drag it into Applications, then open it from there.")
            alert.addButton(withTitle: L10n.tr("打开「应用程序」并退出", "Open Applications and Quit"))
            alert.addButton(withTitle: L10n.tr("暂不", "Not now"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            NSApp.terminate(nil)
            return true
        case .installed:
            return false
        }
    }

    /// Copies the app over any older one (which goes to the Trash), then
    /// opens the copy once this process has quit and ejects the disk image.
    private static func move(_ bundle: URL, unmounting volume: String) -> Bool {
        let files = FileManager.default
        let target = destination(appName: bundle.lastPathComponent,
                                 systemWritable: files.isWritableFile(atPath: "/Applications"),
                                 home: files.homeDirectoryForCurrentUser)
        do {
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: target.path) { try files.trashItem(at: target, resultingItemURL: nil) }
            try files.copyItem(at: bundle, to: target)
        } catch {
            let failure = NSAlert()
            failure.messageText = L10n.tr("没能移到「应用程序」", "Couldn’t move Tact to Applications")
            failure.informativeText = L10n.tr("请退出 Tact，手动把它拖进「应用程序」：\(error.localizedDescription)",
                                              "Quit Tact and drag it into Applications yourself: \(error.localizedDescription)")
            failure.runModal()
            return false
        }
        // The disk image stays busy until this process exits; a shell waits
        // for that, then opens the moved copy and ejects the image.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; "
                                + "/usr/bin/open \"$2\"; /usr/bin/hdiutil detach \"$3\" -quiet || true",
                              "relaunch", String(ProcessInfo.processInfo.processIdentifier), target.path, volume]
        do {
            try relaunch.run()
        } catch {
            NSWorkspace.shared.open(target)
        }
        NSApp.terminate(nil)
        return true
    }
}
