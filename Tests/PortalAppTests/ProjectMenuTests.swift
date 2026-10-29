#if os(macOS)
import AppKit
import Testing
@testable import PortalApp

struct ProjectMenuTests {
    @Test @MainActor func projectTitleSurvivesUpdatesWhileTracking() {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }
        let menu = NSMenu()
        menu.addItem(withTitle: "Portal", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Portal")
        let item = menu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "File")
        application.mainMenu = menu
        let delegate = AppDelegate()
        (delegate as NSApplicationDelegate).applicationDidFinishLaunching?(Notification(name: NSApplication.didFinishLaunchingNotification))
        AppDelegate.nameProjectMenu(in: menu)

        // Tracking can reset only the menu-bar item, without an app-update callback.
        item.title = "File"
        #expect(item.title == "Project")
        #expect(item.submenu?.title == "Project")
        item.submenu?.title = "File"
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: item.submenu)
        #expect(item.title == "Project")
        #expect(item.submenu?.title == "Project")
        #expect(menu.items.count == 2)
        withExtendedLifetime(delegate) {}
    }

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
