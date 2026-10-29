#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PortalApp
import PortalCore

#if os(macOS)
extension PortalAppTestSuite {

@Test("Git tree width defaults wide and survives closing and reopening the window")
@MainActor
func gitTreeColumnWidthIsRemembered() throws {
    NSApplication.shared.finishLaunching()
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: "/tmp", machine: "test")
    model.selectedProjectName = "project"
    model.projectSnapshot = RepositorySnapshot(commits: [], references: [], head: nil, branches: [])
    model.helperAvailable = true
    func openWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ProjectBrowserView(model: model, defaults: defaults))
        window.makeKeyAndOrderFront(nil)
        // A scene first lays out at its minimum size before restoring its window frame.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        window.setContentSize(NSSize(width: 1530, height: 960))
        return window
    }
    func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 3 { return split }
        return view.subviews.lazy.compactMap { splitView(in: $0) }.first
    }
    func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try #require(condition())
    }

    let first = openWindow()
    defer { first.close() }
    try waitUntil { abs(defaults.double(forKey: "git-tree-column-width") - 440) <= 1 }
    let content = try #require(first.contentView)
    let split = try #require(splitView(in: content))
    let column = split.arrangedSubviews[1]
    // On macOS 27 the native pane also includes the space behind the floating sidebar.
    let resizedPaneWidth = column.frame.width + 80
    split.setPosition(column.frame.minX + resizedPaneWidth, ofDividerAt: 1)
    try waitUntil { abs(defaults.double(forKey: "git-tree-column-width") - 520) <= 1 }
    first.close()

    let second = openWindow()
    defer { second.close() }
    try waitUntil {
        guard let content = second.contentView, let split = splitView(in: content) else { return false }
        return abs(split.arrangedSubviews[1].frame.width - resizedPaneWidth) <= 1
            && abs(defaults.double(forKey: "git-tree-column-width") - 520) <= 1
    }
}

}
#endif
#endif
