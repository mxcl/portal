#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import PortalApp
import PortalCore
import PortalGraph

#if os(macOS)
extension PortalAppTestSuite {

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
@Test("Reference insertion resolves host labels and quotes shell metacharacters")
@MainActor
func referenceArguments() {
    let model = AppModel(connectToHelper: false)
    let refs = [RepositoryReference(fullName: "refs/heads/feature/Case", oid: "abc"),
                RepositoryReference(fullName: "refs/tags/v1.0", oid: "abc"),
                RepositoryReference(fullName: "refs/heads/fix'$HOME", oid: "def"),
                RepositoryReference(fullName: "refs/sync/peer/tags/v2", oid: "def")]
    model.projectSnapshot = RepositorySnapshot(commits: [], references: refs, head: nil, branches: [])
    for ref in refs {
        let name = RepositoryReference.graphNames([ref], hosts: [], sourceMachine: nil,
            allReferences: refs, tags: ref.isGraphTag, localMachine: model.configuration.machine).first!
        let expected = ref.fullName.hasPrefix("refs/sync/") ? ref.fullName : ref.name
        if expected.contains("'") {
            #expect(model.gitReferenceArgument(name) == "'fix'\\''$HOME'")
        } else {
            #expect(model.gitReferenceArgument(name) == expected)
        }
    }
    #expect(model.gitReferenceArgument(String(repeating: "a", count: 40)) == String(repeating: "a", count: 40))
}

@Test("SHA insertion button keeps the compact SHA width")
@MainActor
func commitSHALayout() {
    let sha = String(repeating: "a123", count: 10)
    let reference = NSHostingView(rootView: Text(sha.prefix(8)).monospaced()
        .padding(.horizontal, 5).padding(.vertical, 1).font(.caption))
    let button = NSHostingView(rootView: CommitSHA(sha: sha).font(.caption))
    #expect(button.fittingSize == reference.fittingSize)
}

}
#endif
#endif
