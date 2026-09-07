import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncCore
import GitSyncGraph

@Test("Selecting working changes loads both index sides, refreshes, and clears when clean")
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
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    try await finishLoading()
    #expect(model.workingDiffStaged)
    #expect(model.selectedCommitDiff?.contains("+staged") == true)
    try Data("unstaged\n".utf8).write(to: project.appendingPathComponent("file.txt"))
    model.workingDiffStaged = false
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    try await finishLoading()
    #expect(model.selectedCommitDiff?.contains("-staged\n+unstaged") == true)
    try Data("refreshed\n".utf8).write(to: project.appendingPathComponent("file.txt"))
    model.refreshProject()
    try await finishLoading()
    #expect(model.selectedCommitID == CommitGraphGenerator.workingChangesID)
    #expect(model.selectedCommitDiff?.contains("+refreshed") == true)
    _ = try Git.run(["-C", project.path, "add", "."])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-qm", "Initial commit"])
    model.refreshProject()
    try await finishLoading()
    #expect(model.selectedCommitID == nil)
    #expect(model.selectedCommitDiff == nil)
}
