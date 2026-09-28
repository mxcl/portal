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

@Test("View preference reloads detached worktrees and clears a hidden selection")
@MainActor
func detachedWorktreeToggle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    let detached = root.appendingPathComponent("detached")
    let preference = UserDefaults.standard.object(forKey: "show-detached-worktrees")
    defer {
        UserDefaults.standard.set(preference, forKey: "show-detached-worktrees")
        try? FileManager.default.removeItem(at: root)
    }
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("commit.gpgsign", "false")] {
        _ = try Git.run(["-C", project.path, "config", key, value])
    }
    _ = try Git.run(["-C", project.path, "commit", "--allow-empty", "-qm", "base"])
    _ = try Git.run(["-C", project.path, "worktree", "add", "--detach", detached.path])
    _ = try Git.run(["-C", detached.path, "commit", "--allow-empty", "-qm", "detached"])
    let oid = try Git.text(["-C", detached.path, "rev-parse", "HEAD"])
    let model = AppModel(connectToHelper: false)
    model.showDetachedWorktrees = false
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
    #expect(model.projectSnapshot?.commits.contains { $0.oid == oid } == false)
    model.showDetachedWorktrees = true
    try await finishLoading()
    #expect(model.projectSnapshot?.commits.contains { $0.oid == oid } == true)
    #expect(model.projectSnapshot?.detachedWorktreeLabels[oid] == ["detached (detached)"])
    #expect(AppModel(connectToHelper: false).showDetachedWorktrees)
    model.selectCommit(oid)
    try await finishLoading()
    model.showDetachedWorktrees = false
    try await finishLoading()
    #expect(model.selectedCommitID == nil)
    #expect(model.projectSnapshot?.commits.contains { $0.oid == oid } == false)

    // A detached source checkout must not leave an orphan staging row when hidden.
    model.projectSnapshot = try Repository(name: "detached", url: detached).snapshot()
    #expect(model.stagingRows.isEmpty)
    model.showDetachedWorktrees = true
    model.projectSnapshot = try Repository(name: "detached", url: detached).snapshot(showDetachedWorktrees: true)
    #expect(model.stagingRows.count == 1)
    try await finishLoading()
}
