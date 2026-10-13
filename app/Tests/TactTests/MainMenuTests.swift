import AppKit
import Testing
@testable import Tact

@MainActor
struct MainMenuTests {
    private func item(_ action: Selector, in menu: NSMenu) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == action }
    }

    @Test func editShortcutsReachTextFields() throws {
        let menu = AppDelegate.makeMainMenu()
        let paste = try #require(item(#selector(NSText.paste(_:)), in: menu))
        #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == .command)
        #expect(item(#selector(NSText.copy(_:)), in: menu)?.keyEquivalent == "c")
        #expect(item(#selector(NSText.cut(_:)), in: menu)?.keyEquivalent == "x")
        #expect(item(#selector(NSText.selectAll(_:)), in: menu)?.keyEquivalent == "a")
        #expect(item(#selector(NSWindow.performClose(_:)), in: menu)?.keyEquivalent == "w")
    }
}
