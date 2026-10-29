#if os(macOS)
import AppKit
import SwiftUI
import Foundation
import Testing
@testable import PortalCore
@testable import PortalApp

#if os(macOS)
extension PortalAppTestSuite {

@Test("Back and Forward restore project, commit, and content tab")
@MainActor
func navigationHistoryRestoresLocation() {
    let model = AppModel(connectToHelper: false)
    model.selectedProjectName = "first"
    model.selectCommit("aaa")
    model.selectedTab = .terminal
    model.selectProject("second")
    model.selectCommit("bbb")

    model.goBack()
    #expect(model.selectedProjectName == "second")
    #expect(model.selectedCommitID == nil)
    model.goBack()
    #expect(model.selectedProjectName == "first")
    #expect(model.selectedCommitID == "aaa")
    #expect(model.selectedTab == .terminal)
    model.goForward()
    #expect(model.selectedProjectName == "second")
    #expect(model.selectedCommitID == nil)
    model.goForward()
    #expect(model.selectedCommitID == "bbb")
    #expect(!model.canGoForward)
}

@Test("A new destination clears forward history; repeated selections do not add entries")
@MainActor
func navigationHistoryBranches() {
    let model = AppModel(connectToHelper: false)
    model.selectedProjectName = "project"
    #expect(!model.canGoBack)
    model.selectCommit("aaa")
    model.selectCommit("aaa")
    model.goBack()
    #expect(model.selectedCommitID == nil)
    #expect(!model.canGoBack)
    #expect(model.canGoForward)
    model.selectCommit("bbb")
    #expect(!model.canGoForward)
    model.goForward()
    #expect(model.selectedCommitID == "bbb")
    model.goBack()
    model.goBack()
    #expect(model.selectedCommitID == nil)
}

@Test("Project loading and refresh preserve history and restored staging tabs")
@MainActor
func navigationHistoryAcrossLoads() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["first", "second"] {
        _ = try Git.run(["init", "-q", root.appendingPathComponent(name).path])
    }
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "test", folders:
        ["first", "second"].map { SyncFolder(name: $0, isLocal: true, availableLocally: true) })
    model.localProjects = Dictionary(uniqueKeysWithValues:
        ["first", "second"].map { ($0, PeerProject(name: $0, placement: .checkedOut)) })
    func finishLoading() async throws {
        let deadline = Date().addingTimeInterval(10)
        while (model.isLoadingProject || model.isLoadingCommitDiff) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isLoadingProject && !model.isLoadingCommitDiff)
        try #require(model.projectError == nil && model.commitDiffError == nil)
    }
    model.selectProject("first")
    try await finishLoading()
    #expect(!model.canGoBack)
    let staging = try #require(model.selectedCommitID)
    model.selectedTab = .diff
    model.selectProject("second")
    try await finishLoading()
    model.goBack()
    try await finishLoading()
    #expect(model.selectedProjectName == "first")
    #expect(model.selectedCommitID == staging)
    #expect(model.selectedTab == .diff)
    #expect(!model.canGoBack)
    model.refreshProject()
    try await finishLoading()
    #expect(!model.canGoBack)
    #expect(model.canGoForward)
    model.goForward()
    try await finishLoading()
    #expect(model.selectedProjectName == "second")
    #expect(model.selectedTab == .terminal)
    #expect(!model.canGoForward)
}

@Test("Navigation toolbar renders in the history column")
@MainActor
func navigationToolbarPlacement() throws {
    NSApplication.shared.finishLaunching()
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: "/tmp", machine: "test")
    model.selectedProjectName = "project"
    model.helperAvailable = true
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: ProjectBrowserView(model: model))
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let deadline = Date().addingTimeInterval(3)
    while window.toolbar?.items.first(where: { $0.label == "Forward" })?.view?.window == nil,
          Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    let items = try #require(window.toolbar?.items)
    let back = try #require(items.first { $0.label == "Back" }?.view)
    let forward = try #require(items.first { $0.label == "Forward" }?.view)
    let sidebar = try #require(items.first {
        $0.itemIdentifier.rawValue == "com.apple.SwiftUI.navigationSplitView.toggleSidebar"
    }?.view)
    func historyColumn(in view: NSView) -> NSView? {
        if let split = view as? NSSplitView, split.arrangedSubviews.count == 3 {
            return split.arrangedSubviews[1]
        }
        return view.subviews.lazy.compactMap { historyColumn(in: $0) }.first
    }
    let content = try #require(window.contentView)
    let column = try #require(historyColumn(in: content))
    #expect(back.convert(back.bounds, to: nil).minX >= sidebar.convert(sidebar.bounds, to: nil).maxX)
    #expect(forward.convert(forward.bounds, to: nil).maxX <= column.convert(column.bounds, to: nil).maxX)

}

}
#endif
#endif
