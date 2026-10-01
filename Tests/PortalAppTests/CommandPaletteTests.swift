#if os(macOS)
import Foundation
import AppKit
import SwiftUI
import Testing
@testable import PortalApp
@testable import PortalCore

@MainActor
@Test func paletteStaysAboveHostedContentWhenWindowResizes() throws {
    let model = AppModel(connectToHelper: false)
    let content = NSHostingView(rootView: ProjectBrowserView(model: model))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = content
    defer { model.dismissPalette(); window.orderOut(nil) }
    content.layoutSubtreeIfNeeded()
    model.showPalette(in: window)
    let container = try #require(content.superview)
    // A child of SwiftUI's hosting view can receive input yet remain invisible.
    // Keep the palette above that entire rendering subtree.
    let overlay = try #require(container.subviews.first { $0 is NSHostingView<PaletteOverlay> })
    #expect(try #require(container.subviews.firstIndex(of: overlay)) > #require(container.subviews.firstIndex(of: content)))
    for size in [NSSize(width: 860, height: 520), NSSize(width: 1400, height: 900)] {
        window.setContentSize(size)
        container.layoutSubtreeIfNeeded()
        #expect(overlay.frame == content.frame)
        #expect(!overlay.isHidden)
    }
    model.dismissPalette()
    #expect(overlay.superview == nil)
}

@MainActor
@Test func paletteFocusesSynchronouslyAndRestoresResponder() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let original = NSTextView(frame: window.contentView!.bounds)
    window.contentView = original
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    window.makeFirstResponder(original)
    let model = AppModel(connectToHelper: false)
    model.showPalette(in: window)
    #expect(model.showingPalette)
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor !== original)
    #expect(editor.isFieldEditor)
    model.dismissPalette()
    let deadline = Date().addingTimeInterval(2)
    while window.firstResponder !== original && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.showingPalette)
    #expect(window.firstResponder === original)
}

@MainActor
@Test func paletteSearchMergesSourcesAndRejectsStaleResults() async throws {
    let search = PaletteSearch()
    let commit = RepositoryCommit(oid: String(repeating: "a", count: 40), parents: [], author: "Test", date: .distantPast, message: "First")
    let other = RepositoryCommit(oid: String(repeating: "b", count: 40), parents: [], author: "Test", date: .distantPast, message: "Second")
    let local = PaletteTarget(project: "project", source: .local, label: "This Mac", priority: 0)
    let remote = PaletteTarget(project: "project", source: .host(UUID()), label: "Peer", priority: 1)
    let backup = PaletteTarget(project: "project", source: .backup("backup"), label: "Backup", priority: 2)
    search.search("main", projects: ["main-project"], targets: [remote, local, backup], hosts: []) { target, _ in
        let commit = target.source == backup.source ? other : commit
        return [RepositorySearchMatch(reference: RepositoryReference(fullName: "refs/heads/main", oid: commit.oid), commit: commit)]
    }
    #expect(search.results.first?.project == "main-project")
    var deadline = Date().addingTimeInterval(30)
    while search.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(search.results.count == 3)
    #expect(search.results.first { $0.match?.commit.oid == commit.oid }?.target?.source == .local)
    #expect(search.results.contains { $0.match?.commit.oid == other.oid })

    search.search("old", projects: [], targets: [remote], hosts: []) { _, _ in
        Thread.sleep(forTimeInterval: 0.4)
        return [RepositorySearchMatch(reference: nil, commit: commit)]
    }
    try await Task.sleep(for: .milliseconds(350))
    search.search("new", projects: ["new-project"], targets: [local], hosts: []) { _, _ in
        throw SyncError.invalidConfiguration("offline")
    }
    deadline = Date().addingTimeInterval(30)
    while search.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(search.results.map(\.title) == ["new-project"])
    #expect(search.failures.count == 1)
    #expect(search.failures.first?.contains("offline") == true)
    search.search("", projects: ["b", "a"], targets: [local], hosts: []) { _, _ in
        Issue.record("Empty search must not read Git")
        return []
    }
    #expect(search.results.map(\.title) == ["a", "b"])
    #expect(search.failures.isEmpty)
    #expect(!search.isLoading)
}

@MainActor
@Test func paletteOpensCommitOutsideLoadedHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["-C", project.path, "init", "-q"])
    var stream = ""
    for i in 1...260 {
        let message = "Commit \(i)"
        stream += "commit refs/heads/main\nmark :\(i)\ncommitter Test <test@example.com> \(i) +0000\ndata \(message.utf8.count)\n\(message)\n"
        if i > 1 { stream += "from :\(i - 1)\n" }
        stream += "\n"
    }
    _ = try Git.run(["-C", project.path, "fast-import", "--quiet"], input: Data(stream.utf8))
    let oid = try Git.text(["-C", project.path, "rev-list", "--max-parents=0", "main"])
    let commit = try Repository(name: "project", url: project).commit(at: oid)
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    let target = try #require(model.paletteTargets.first)
    let result = PaletteResult(project: "project", target: target,
        match: RepositorySearchMatch(reference: nil, commit: commit), title: oid, rank: 0)
    model.openPaletteResult(result)
    let deadline = Date().addingTimeInterval(30)
    while (model.selectedCommitID != oid || model.isLoadingProject || model.isLoadingCommitDiff) && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.selectedCommitID == oid)
    #expect(model.paletteCommit == commit)
    #expect(model.selectedTab == .diff)
    #expect(model.commitDiffError == nil)
    #expect(model.projectSnapshot?.commits.contains { $0.oid == oid } == false)
    // An explicit result can use a backup even when this Mac has the project,
    // if that backup contains a commit missing from the local object database.
    let backups = root.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    let bare = backups.appendingPathComponent("project.git")
    _ = try Git.run(["clone", "--bare", project.path, bare.path])
    let tree = try Git.text(["-C", bare.path, "rev-parse", "main^{tree}"])
    let backupOID = try Git.text(["-C", bare.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
        "commit-tree", tree, "-p", oid, "-m", "Backup-only commit"])
    _ = try Git.run(["-C", bare.path, "update-ref", "refs/heads/main", backupOID])
    model.configuration.backupDestination = BackupDestinationConfiguration(root: backups.path)
    model.backupItems = try BackupIndex(url: root.appendingPathComponent("index.json")).items(in: backups)
    let backupTarget = try #require(model.paletteTargets.first { if case .backup = $0.source { return true }; return false })
    let backupMatch = try #require(AppModel.search(backupTarget, query: backupOID, configuration: model.configuration).first)
    model.openPaletteResult(PaletteResult(project: "project", target: backupTarget, match: backupMatch, title: backupOID, rank: 0))
    let backupDeadline = Date().addingTimeInterval(30)
    while (model.selectedCommitID != backupOID || model.isLoadingProject || model.isLoadingCommitDiff) && Date() < backupDeadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.selectedCommitID == backupOID)
    #expect(model.commitDiffError == nil)
    #expect(model.selectedCommitDiff != nil)

    model.openPaletteResult(result)
    model.selectCommit(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.selectedCommitID == nil)
}
#endif
