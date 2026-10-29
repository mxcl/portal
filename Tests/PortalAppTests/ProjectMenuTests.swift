#if os(macOS)
import AppKit
import Testing
@testable import PortalApp

struct ProjectMenuTests {
    @Test @MainActor func projectComesAfterAppMenuAndStaysThere() {
        let menu = NSMenu()
        for title in ["Portal", "File", "Edit", "View", "Project", "Window"] {
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        AppDelegate.placeProjectMenuFirst(in: menu)
        AppDelegate.placeProjectMenuFirst(in: menu)
        #expect(menu.items.map(\.title) == ["Portal", "Project", "File", "Edit", "View", "Window"])
        menu.removeItem(at: 1)
        AppDelegate.placeProjectMenuFirst(in: menu)
        #expect(menu.items.map(\.title) == ["Portal", "File", "Edit", "View", "Window"])
    }
}
#endif
