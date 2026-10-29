#if os(macOS)
import AppKit
import Testing
@testable import PortalApp

struct ProjectMenuTests {
    @Test @MainActor func projectMenuKeepsSwiftUIMenuSlots() {
        let menu = NSMenu()
        for title in ["Portal", "File", "Edit", "View", "Window"] {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
        }
        let originalItems = menu.items
        let file = originalItems[1]
        let originalSubmenu = file.submenu
        let action = file.submenu!.addItem(withTitle: "Switch Project…", action: nil, keyEquivalent: "p")

        for _ in 0..<10 {
            // SwiftUI may restore the standard title when it rebuilds its commands.
            file.title = "File"
            file.submenu?.title = "File"
            AppDelegate.nameProjectMenu(in: menu)
            #expect(menu.items.map(\.title) == ["Portal", "Project", "Edit", "View", "Window"])
            #expect(file.submenu?.title == "Project")
            #expect(menu.items == originalItems)
            #expect(file.submenu === originalSubmenu)
            #expect(file.submenu?.items.first === action)
            AppDelegate.nameProjectMenu(in: menu)
            #expect(menu.items == originalItems)
        }
    }
}
#endif
