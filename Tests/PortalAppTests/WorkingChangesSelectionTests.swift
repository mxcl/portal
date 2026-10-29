import Foundation
import Testing
@testable import PortalApp
@testable import PortalCore
@testable import PortalEngine
import PortalGraph

#if os(macOS)
extension PortalAppTestSuite {

@Test("Staging selects the diff, loads both index sides, and stays selected when clean")
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
    #expect(model.availableTabs == ProjectTab.allCases)
    #expect(model.toolbarTabs == [.diff])
    model.selectNextStaging()
    try await finishLoading()
    #expect(model.selectedCommitID == CommitGraphGenerator.workingChangesID)
    #expect(model.toolbarTabs == [.diff, .terminal])
    #expect(model.selectedTab == .diff)
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
    #expect(model.showsCommitDiff)
    try await finishLoading()
    #expect(model.selectedTab == .diff)
    #expect(model.availableTabs == ProjectTab.allCases)
    model.selectCommit(CommitGraphGenerator.workingChangesID)
    #expect(!model.showsCommitDiff)
    try await finishLoading()
    #expect(model.selectedTab == .diff)
}

@Test("Peer staging keeps its own HEAD and files and opens its remote diff")
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
    model.selectNextStaging()
    try await finishLoading()
    #expect(model.selectedCommitID == local.id)
    model.selectNextStaging()
    try await finishLoading()
    #expect(model.selectedCommitID == peer.id)
    #expect(model.toolbarTabs == [.diff, .terminal])
    #expect(model.selectedStaging?.source == .host(host.id))
    #expect(model.selectedTab == .diff)
    #expect(model.availableTabs == ProjectTab.allCases)
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
    model.selectNextStaging()
    try await finishLoading()
    #expect(model.selectedCommitID == local.id)
    #expect(model.selectedTab == .diff)
    #expect(model.selectedTerminalHost == nil)
    #expect(model.selectedTerminalDirectory?.path == project.path)
    #expect(model.selectedCommitDiff?.contains("+local") == true)
    model.configuration.folders[0].availableHosts.insert(host.id)
    model.remoteProjects[host.id] = ["project": PeerProject(name: "project", placement: .checkedOut)]
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

    // Even with an unusable SSH target, staging is available from pushed state.
    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: model.configuration, support: root.appendingPathComponent("support"))
    var snapshot = engine.snapshot()
    let pushed = RepositorySnapshot(commits: [], references: [], head: "main", branches: ["main"],
        headOID: "pushed-head", workingChanges: RepositoryWorkingChanges(porcelain: Data("A  pushed\0".utf8)))
    snapshot.observedProjects = [host.id: ["project": ObservedProject(
        project: PeerProject(name: "project", placement: .checkedOut), snapshot: pushed,
        status: "main · 1 changed", revision: UUID())]]
    model.apply(snapshot)
    await model.refreshPeerStaging()
    #expect(model.peerSnapshots[host.id] == pushed)
    #expect(!model.isLoadingPeerStaging)
}

@Test("Auxiliary History preference reloads snapshots and worktrees and clears a hidden selection")
@MainActor
func auxiliaryHistoryToggle() async throws {
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
    _ = try Git.run(["-C", project.path, "update-ref", "refs/codex/snapshots/1234567890abcdef", oid])
    let model = AppModel(connectToHelper: false)
    model.showAuxiliaryHistory = false
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
    model.showAuxiliaryHistory = true
    try await finishLoading()
    #expect(model.projectSnapshot?.commits.contains { $0.oid == oid } == true)
    #expect(model.projectSnapshot?.auxiliaryHistoryLabels[oid] == ["detached (detached)", "Codex snapshot 12345678"])
    #expect(AppModel(connectToHelper: false).showAuxiliaryHistory)
    model.selectCommit(oid)
    try await finishLoading()
    model.showAuxiliaryHistory = false
    try await finishLoading()
    #expect(model.selectedCommitID == nil)
    #expect(model.projectSnapshot?.commits.contains { $0.oid == oid } == false)

    // A detached source checkout must not leave an orphan staging row when hidden.
    model.projectSnapshot = try Repository(name: "detached", url: detached).snapshot()
    #expect(model.stagingRows.isEmpty)
    let selection = model.selectedCommitID
    model.selectNextStaging()
    #expect(model.selectedCommitID == selection)
    model.showAuxiliaryHistory = true
    model.projectSnapshot = try Repository(name: "detached", url: detached).snapshot(showAuxiliaryHistory: true)
    #expect(model.stagingRows.count == 1)
    try await finishLoading()
}

@Test("Project refresh clears the sidebar dot after tracking refs catch up, despite stale inventory")
@MainActor
func sidebarRefreshAfterPush() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    func git(_ args: [String]) throws -> String { try Git.text(["-C", project.path] + args) }
    _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "base"])
    _ = try git(["remote", "add", "origin", "https://github.com/test/project.git"])
    _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
    _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "ahead"])
    let repository = Repository(name: "project", url: project)
    let stale = PeerProject(name: "project", placement: .checkedOut, defaultBranch: "main",
                            branchTips: try repository.branchTips())
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.localProjects = ["project": stale]
    model.selectedProjectName = "project"
    func refresh() async throws {
        model.refreshProject()
        let deadline = Date().addingTimeInterval(10)
        while model.isLoadingProject && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isLoadingProject && model.projectError == nil)
    }
    try await refresh()
    #expect(model.hasBranchDifferences(for: "project"))
    // A successful push updates this tracking ref; no network is needed to reproduce it.
    _ = try git(["update-ref", "refs/remotes/origin/main", "HEAD"])
    try await refresh()
    model.localProjects = ["project": stale]
    #expect(!model.hasBranchDifferences(for: "project"))
    let host = SyncHost(machine: "peer", peer: "peer", root: "/unused")
    model.configuration.hosts = [host]
    model.remoteProjects[host.id] = ["project": PeerProject(name: "project", placement: .checkedOut,
        defaultBranch: "main", branchTips: RepositoryBranchTips(local: ["main": "stale"], github: [:]))]
    let snapshot = try #require(model.projectSnapshot)
    // Older peer content still has fresh local refs even without branchTips metadata.
    model.peerSnapshots[host.id] = RepositorySnapshot(commits: [], references: snapshot.references,
        head: snapshot.head, branches: snapshot.branches)
    #expect(!model.hasBranchDifferences(for: "project"))
}

@Test("Selecting a project opens its staging terminal and refresh preserves the chosen tab")
@MainActor
func projectSelectionOpensStagingTerminal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", project.path])
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: root.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.localProjects = ["project": PeerProject(name: "project", placement: .checkedOut)]
    func finishLoading() async throws {
        let deadline = Date().addingTimeInterval(10)
        while (model.isLoadingProject || model.isLoadingCommitDiff) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!model.isLoadingProject && !model.isLoadingCommitDiff)
        try #require(model.projectError == nil && model.commitDiffError == nil)
    }
    model.selectProject("project")
    try await finishLoading()
    #expect(model.selectedCommitID == CommitGraphGenerator.workingChangesID)
    #expect(model.selectedTab == .terminal)
    #expect(model.selectedProjectHostSource == .local)
    #expect(model.selectedTerminalDirectory?.path == project.path)
    model.selectedTab = .diff
    model.refreshProject()
    try await finishLoading()
    #expect(model.selectedCommitID == CommitGraphGenerator.workingChangesID)
    #expect(model.selectedTab == .diff)
}

@Test("Staging groups only matching SHAs and host tabs follow grouped and diverged checkouts")
@MainActor
func groupedStagingSelection() async throws {
    let host = SyncHost(machine: "peer", peer: "", root: "/remote")
    let model = AppModel(connectToHelper: false)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", root.appendingPathComponent("project").path])
    model.configuration = AppConfiguration(root: root.path, machine: "local", hosts: [host],
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)])
    model.localProjects = ["project": PeerProject(name: "project", placement: .checkedOut)]
    model.selectedProjectName = "project"
    model.refreshProject()
    let deadline = Date().addingTimeInterval(10)
    while model.isLoadingProject && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!model.isLoadingProject && model.projectError == nil)
    model.selectedProjectName = nil
    func snapshot(_ sha: String?) -> RepositorySnapshot {
        RepositorySnapshot(commits: [], references: [], head: "main", branches: ["main"],
            headOID: sha, workingChanges: RepositoryWorkingChanges(porcelain: Data(" M file\0".utf8)))
    }
    model.projectSnapshot = snapshot("same")
    model.peerSnapshots[host.id] = snapshot("same")
    let row = try #require(model.stagingRows.first)
    #expect(model.stagingRows.count == 1)
    #expect(row.checkouts.map(\.source) == [.local, .host(host.id)])
    model.selectCommit(row.id)
    model.selectProjectHost(.host(host.id))
    #expect(model.selectedStaging?.source == .host(host.id))
    #expect(model.selectedStagingRowID == row.id)
    #expect(model.selectedTab == .terminal)
    model.peerSnapshots[host.id] = snapshot("different")
    #expect(model.stagingRows.count == 2)
    #expect(model.selectedStagingRowID == model.stagingRows.last?.id)
    model.selectProjectHost(.local)
    #expect(model.selectedStaging?.source == .local)
    #expect(model.selectedStagingRowID == row.id)
    model.projectSnapshot = snapshot(nil)
    model.peerSnapshots[host.id] = snapshot(nil)
    #expect(model.stagingRows.count == 2)
}

}
#endif
