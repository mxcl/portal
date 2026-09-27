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
    #expect(model.availableTabs == [.info, .diff, .terminal])
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
    #expect(model.availableTabs == [.info, .diff, .terminal])
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    try await finishLoading()
    #expect(model.selectedTab == .editor)
}

@Test("Peer staging keeps its own HEAD and files and cannot open the local editor or diff")
@MainActor
func peerWorkingChangesSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", project.path])
    try Data("local\n".utf8).write(to: project.appendingPathComponent("local.txt"))
    _ = try Git.run(["-C", project.path, "add", "."])
    let host = SyncHost(machine: "Pangolin", peer: "", root: "/remote/projects", executable: "/unused")
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "Maliwan", hosts: [host],
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.localProjects = ["project": PeerProject(name: "project", placement: .checkedOut)]
    model.selectedProjectName = "project"
    model.refreshProject()
    func finishLoading() async throws {
        let deadline = Date().addingTimeInterval(10)
        while (model.isLoadingProject || model.isLoadingCommitDiff || model.isLoadingPeerStaging) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isLoadingProject && !model.isLoadingCommitDiff && !model.isLoadingPeerStaging)
    }
    try await finishLoading()
    model.peerSnapshots[host.id] = RepositorySnapshot(commits: [], references: [], head: "main", branches: ["main"],
        headOID: "older-head", workingChanges: RepositoryWorkingChanges(porcelain: Data("A  bar\0".utf8)))
    let local = try #require(model.stagingRows.first)
    let peer = try #require(model.stagingRows.last)
    #expect(model.stagingRows.count == 2)
    #expect(local.id != peer.id)
    #expect(peer.host == "Pangolin")
    #expect(peer.graphCommit.parents == ["older-head"])
    #expect(peer.snapshot.workingChanges?.files?.map(\.path) == ["bar"])
    model.selectCommit(peer.id)
    try await finishLoading()
    #expect(model.selectedStaging?.source == .host(host.id))
    #expect(model.selectedTab == .diff)
    #expect(model.availableTabs == [.info, .diff, .terminal])
    #expect(model.selectedTerminalHost?.id == host.id.uuidString)
    #expect(model.selectedTerminalDirectory?.path == "/remote/projects/project")
    #expect(model.workingDiffStaged)
    // Invalid peer configuration must fail the remote read instead of showing local changes.
    #expect(model.commitDiffError != nil)
    #expect(model.selectedCommitDiff == nil)
    model.peerSnapshots[host.id] = RepositorySnapshot(commits: [], references: [], head: "main", branches: ["main"],
        headOID: "older-head", workingChanges: RepositoryWorkingChanges(porcelain: Data()))
    #expect(model.selectedStaging?.id == peer.id)
    #expect(model.selectedStaging?.snapshot.workingChanges?.isEmpty == true)
    model.selectCommit(local.id)
    try await finishLoading()
    #expect(model.selectedTab == .editor)
    #expect(model.selectedTerminalHost == nil)
    #expect(model.selectedTerminalDirectory?.path == project.path)
    #expect(model.selectedCommitDiff?.contains("+local") == true)
    model.configuration.folders[0].availableHosts.insert(host.id)
    model.showNextProjectTerminal()
    #expect(model.selectedTab == .terminal)
    #expect(model.selectedTerminalHost == nil)
    model.showNextProjectTerminal()
    #expect(model.selectedTerminalHost?.id == host.id.uuidString)
    #expect(model.selectedTerminalDirectory?.path == "/remote/projects/project")
    model.showNextProjectTerminal()
    #expect(model.selectedTerminalHost == nil)
    #expect(model.selectedTerminalDirectory?.path == project.path)
    await model.refreshPeerStaging()
    #expect(model.peerSnapshots[host.id] == nil)
    #expect(model.peerStagingErrors[host.id] != nil)
    #expect(model.stagingRows.map(\.id) == [local.id])
    #expect(model.selectedCommitID == local.id)
}
