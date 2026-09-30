#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import GitSyncApp
import GitSyncCore
import GitSyncGraph

@Test("Copy uses the full selected SHA, yields to text, and ignores staging")
@MainActor
func selectedCommitCopyCommand() throws {
    NSApplication.shared.finishLaunching()
    let pasteboard = NSPasteboard.general
    let saved = pasteboard.pasteboardItems?.map { item in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    } ?? []
    defer {
        pasteboard.clearContents()
        pasteboard.writeObjects(saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        })
    }
    let model = AppModel(connectToHelper: false)
    let sha = String(repeating: "a123", count: 10)
    let commit = RepositoryCommit(oid: sha, parents: [], author: "Test", date: .distantPast, message: "First")
    model.configuration = AppConfiguration(root: "/tmp", machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.selectedProjectName = "project"
    model.projectSnapshot = RepositorySnapshot(commits: [commit], references: [], head: nil, branches: [])
    model.selectedCommitID = sha
    model.selectedTab = .diff
    model.helperAvailable = true
    let window = NSWindow(contentViewController: NSHostingController(rootView: ProjectBrowserView(model: model)))
    window.styleMask = [.titled, .closable, .resizable]
    window.setContentSize(NSSize(width: 1180, height: 720))
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let history = try #require(window.firstResponder as? NSTableView)
    let copy = #selector(NSText.copy(_:))
    pasteboard.clearContents()
    let handled = history.tryToPerform(copy, with: nil)
    #expect(handled)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    #expect(pasteboard.string(forType: .string) == sha)

    let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    text.string = "selected text"
    window.contentView?.addSubview(text)
    window.makeFirstResponder(text)
    text.selectAll(nil)
    let textHandled = text.tryToPerform(copy, with: nil)
    #expect(textHandled)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    #expect(pasteboard.string(forType: .string) == "selected text")
    text.removeFromSuperview()
    window.makeFirstResponder(history)

    for selection in [CommitGraphGenerator.workingChangesID, nil] {
        model.selectedCommitID = selection
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(model.selectedCommit == nil)
        #expect(pasteboard.string(forType: .string) == "selected text")
    }
}
@Test("SHA copy bubble reserves no action space in idle, hover, or copied states")
@MainActor
func commitCopyBubbleLayout() {
    let sha = String(repeating: "a123", count: 10)
    let reference = NSHostingView(rootView: Text(sha.prefix(8)).monospaced()
        .padding(.horizontal, 5).padding(.vertical, 1).font(.caption))
    let expected = reference.fittingSize
    for (hovered, copied) in [(false, false), (true, false), (true, true)] {
        let bubble = NSHostingView(rootView: CopyableCommitSHA(sha: sha, isHovered: hovered, isCopied: copied)
            .font(.caption))
        #expect(bubble.fittingSize == expected)
    }
}
#endif
