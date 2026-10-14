import Foundation
import Testing
@testable import Tact

struct RelocationTests {
    @Test func anAppOnAMountedDiskImageOffersToMove() {
        #expect(Relocation.place(of: "/Volumes/Tact 1/Tact.app", readOnly: true) == .diskImage(volume: "/Volumes/Tact 1"))
        #expect(Relocation.place(of: "/Volumes/Tact/Tact.app", readOnly: true) == .diskImage(volume: "/Volumes/Tact"))
    }

    /// Someone who keeps apps on an external drive is not asked to move.
    @Test func installedAppsStayPut() {
        #expect(Relocation.place(of: "/Applications/Tact.app", readOnly: false) == .installed)
        #expect(Relocation.place(of: "/Users/someone/Applications/Tact.app", readOnly: false) == .installed)
        #expect(Relocation.place(of: "/Volumes/External/Apps/Tact.app", readOnly: false) == .installed)
        #expect(Relocation.place(of: "/Applications/Tact.app", readOnly: true) == .installed, "a read-only system volume is not a disk image")
    }

    @Test func aTranslocatedCopyCannotMoveItself() {
        let path = "/private/var/folders/x1/abc/T/AppTranslocation/0F2A-11/d/Tact.app"
        #expect(Relocation.place(of: path, readOnly: true) == .translocated)
    }

    @Test func theMoveGoesToApplicationsOrTheUsersOwn() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        #expect(Relocation.destination(appName: "Tact.app", systemWritable: true, home: home).path == "/Applications/Tact.app")
        #expect(Relocation.destination(appName: "Tact.app", systemWritable: false, home: home).path == "/Users/someone/Applications/Tact.app")
    }
}
