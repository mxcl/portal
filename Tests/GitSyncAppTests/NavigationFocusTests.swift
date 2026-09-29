#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import GitSyncApp
import GitSyncCore

@Test("Overview focuses projects and Diff focuses Git history")
@MainActor
func navigationTransfersListFocus() throws {
    NSApplication.shared.finishLaunching()
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: "/tmp", machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.selectedProjectName = "project"
    model.projectSnapshot = RepositorySnapshot(commits: [], references: [], head: nil, branches: [])
    model.helperAvailable = true
    let window = NSWindow(contentViewController: NSHostingController(rootView: ProjectBrowserView(model: model, defaults: defaults)))
    window.setContentSize(NSSize(width: 1180, height: 720))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }

    for tab in [ProjectTab.diff, .info, .diff] {
        model.selectedTab = tab
        let deadline = Date().addingTimeInterval(2)
        var focused = false
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if let table = window.firstResponder as? NSTableView {
                focused = (table.style == .sourceList) == (tab == .info)
            }
        } while !focused && Date() < deadline
        #expect(focused, "Expected list focus for \(tab), got \(String(describing: window.firstResponder))")
    }
}
#endif
