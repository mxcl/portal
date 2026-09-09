import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncCore
import GitSyncGraph

@Test("Staging opens the editor, loads both index sides, and stays selected when clean")
@MainActor
func workingChangesSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", project.path])
    try Data("staged\n".utf8).write(to: project.appendingPathComponent("file.txt"))
    _ = try Git.run(["-C", project.path, "add", "."])
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.localProjects = ["project": PeerProject(name: "project", placement: .checkedOut)]
    model.selectedProjectName = "project"
    model.refreshProject()
    func finishLoading() async throws {
        let deadline = Date().addingTimeInterval(10)
        while (model.isLoadingProject || model.isLoadingCommitDiff) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isLoadingProject && !model.isLoadingCommitDiff)
        try #require(model.projectError == nil && model.commitDiffError == nil)
    }
    try await finishLoading()
    #expect(model.availableTabs == [.info, .diff])
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    try await finishLoading()
    #expect(model.selectedTab == .editor)
    #expect(model.availableTabs == ProjectTab.allCases)
    #expect(model.workingDiffStaged)
    #expect(model.selectedCommitDiff?.contains("+staged") == true)
    try Data("unstaged\n".utf8).write(to: project.appendingPathComponent("file.txt"))
    model.workingDiffStaged = false
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    try await finishLoading()
    #expect(model.selectedCommitDiff?.contains("-staged\n+unstaged") == true)
    model.selectedTab = .diff
    try Data("refreshed\n".utf8).write(to: project.appendingPathComponent("file.txt"))
    model.refreshProject()
    try await finishLoading()
    #expect(model.selectedCommitID == CommitGraphGenerator.workingChangesID)
    #expect(model.selectedTab == .diff)
    #expect(model.selectedCommitDiff?.contains("+refreshed") == true)
    _ = try Git.run(["-C", project.path, "add", "."])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-qm", "Initial commit"])
    model.refreshProject()
    try await finishLoading()
    #expect(model.projectSnapshot?.workingChanges?.isEmpty == true)
    #expect(model.selectedCommitID == CommitGraphGenerator.workingChangesID)
    #expect(model.selectedCommitDiff == "")
    model.selectCommit(try #require(model.projectSnapshot?.headOID))
    try await finishLoading()
    #expect(model.selectedTab == .diff)
    #expect(model.availableTabs == [.info, .diff])
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    try await finishLoading()
    #expect(model.selectedTab == .editor)
}
