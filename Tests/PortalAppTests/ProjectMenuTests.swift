#if os(macOS)
import AppKit
import Testing
@testable import PortalApp
@testable import PortalCore

#if os(macOS)
extension PortalAppTestSuite {

struct ProjectMenuTests {
    @Test @MainActor func terminalCommandsFollowVisibleHostPane() {
        let model = AppModel(connectToHelper: false)
        let host = SyncHost(machine: "Remote", peer: "example", root: "/projects")
        model.configuration = AppConfiguration(root: "/projects", machine: "test",
            hosts: [host], folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
        model.selectedProjectName = "project"
        model.localProjects = ["project": PeerProject(name: "project", placement: .checkedOut)]
        model.remoteProjects = [host.id: ["project": PeerProject(name: "project", placement: .checkedOut)]]
        for source in [ProjectSource.local, .host(host.id)] {
            model.terminalSource = source
            for tab in ProjectTab.allCases {
                model.selectedTab = tab
                #expect(model.showsProjectTerminal)
            }
        }
        model.selectedCommitID = "commit"
        #expect(!model.showsProjectTerminal)
        model.selectedCommitID = nil
        model.remoteProjects[host.id]?["project"] = PeerProject(name: "project", placement: .mirrored)
        #expect(!model.showsProjectTerminal)
        model.selectedProjectName = nil
        #expect(!model.showsProjectTerminal)
    }

    @Test func projectNavigationFollowsVisibleSidebarOrder() {
        let projects = ["zebra", "alpha", "archived"]
        let middle = ProjectNavigation(projects: projects, selected: "alpha")
        #expect(middle.previous == "zebra")
        #expect(middle.next == "archived")
        #expect(ProjectNavigation(projects: projects, selected: "zebra").previous == nil)
        #expect(ProjectNavigation(projects: projects, selected: "archived").next == nil)
        for selected in [nil, "filtered-out"] as [String?] {
            let navigation = ProjectNavigation(projects: projects, selected: selected)
            #expect(navigation.previous == "archived")
            #expect(navigation.next == "zebra")
        }
        let empty = ProjectNavigation(projects: [], selected: "alpha")
        #expect(empty.previous == nil)
        #expect(empty.next == nil)
        let single = ProjectNavigation(projects: ["alpha"], selected: "alpha")
        #expect(single.previous == nil)
        #expect(single.next == nil)
    }

    @Test @MainActor func projectTitleSurvivesUpdatesWhileTracking() {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }
        let menu = NSMenu()
        menu.addItem(withTitle: "Portal", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Portal")
        let item = menu.addItem(withTitle: "File", action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: "File")
        application.mainMenu = menu
        AppDelegate.nameProjectMenu(in: menu)

        // Tracking can reset only the menu-bar item, without an app-update callback.
        item.title = "File"
        #expect(item.title == "Project")
        #expect(item.submenu?.title == "Project")
        item.submenu?.title = "File"
        #expect(item.title == "Project")
        #expect(item.submenu?.title == "Project")
        #expect(menu.items.count == 2)
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

}
#endif
#endif
