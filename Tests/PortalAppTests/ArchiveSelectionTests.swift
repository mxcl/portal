import Foundation
import Testing
@testable import PortalApp
@testable import PortalCore
@testable import PortalEngine

@Test("archiving keeps the selected project, commit, and content while switching to its backup")
@MainActor
func archivePreservesSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    let backup = root.appendingPathComponent("backup")
    let support = root.appendingPathComponent("support")
    for directory in [source, backup, support] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let savedSelection = UserDefaults.standard.object(forKey: "selected-project-v2")
    defer { UserDefaults.standard.set(savedSelection, forKey: "selected-project-v2") }
    let project = source.appendingPathComponent("project")
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    try Data("# Project\n".utf8).write(to: project.appendingPathComponent("README.md"))
    _ = try Git.run(["-C", project.path, "add", "."])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-q", "-m", "Initial commit"])
    let oid = try Git.text(["-C", project.path, "rev-parse", "HEAD"])
    try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "test",
                     stateURL: root.appendingPathComponent("state.json"), bareDestination: true)
    let destination = BackupDestinationConfiguration(root: backup.path)
    let model = AppModel(connectToHelper: false)
    #expect(model.backupStatus(for: "project").title == "Backup not configured")
    model.configuration = AppConfiguration(root: source.path, machine: "test",
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)],
        backupDestination: destination)
    #expect(model.backupStatus(for: "project").title == "No backup found")
    #expect(model.openProjectURL(URL(string: "gitsync://project?name=project")!))
    #expect(model.selectedProjectName == "project")
    #expect(!model.openProjectURL(URL(string: "gitsync://project?name=..%2Foutside")!))
    #expect(model.selectedProjectName == "project")
    var deadline = Date().addingTimeInterval(5)
    while model.isLoadingProject && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    model.selectCommit(oid)
    deadline = Date().addingTimeInterval(5)
    while model.isLoadingCommitDiff && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let diff = try #require(model.selectedCommitDiff)
    // A List may send the same selection again when the row changes sections.
    model.selectProject("project")
    #expect(model.selectedCommitID == oid)

    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: AppConfiguration(root: source.path, machine: "test",
            folders: [SyncFolder(name: "project")], backupDestination: destination), support: support)
    let indexURL = support.appendingPathComponent("backup-index-\(destination.id.uuidString).json")
    try BackupIndex(url: indexURL).replaceCatalog(machine: "test", repositories: [])
    try engine.loadBackupIndex()
    deadline = Date().addingTimeInterval(5)
    while engine.backupItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(engine.backupItems.first?.status == .archived)
    model.apply(engine.snapshot())
    #expect(model.backupStatus(for: "project").title == "Backup available")
    #expect(model.backupStatus(for: "project").detail.contains("test"))
    #expect(model.backupStatus(for: "another-project").title == "No backup found")
    model.backupError = "Backup host offline"
    #expect(model.backupStatus(for: "project").title == "Backup status unavailable")
    #expect(model.backupStatus(for: "project").detail == "Backup host offline")
    model.backupError = nil
    model.helperError = "Helper unavailable"
    #expect(model.backupStatus(for: "project").title == "Backup status unavailable")
    model.helperError = nil
    #expect(model.selectedProjectName == "project")
    #expect(model.selectedCommitID == oid)
    #expect(model.projectReadme?.markdown == "# Project\n")
    #expect(model.selectedCommitDiff == diff)
    #expect(model.projectSnapshot?.commits.contains(where: { $0.oid == oid }) == true)
    #expect(model.projectNames.isEmpty)
    #expect(model.archivedProjects.map(\.name) == ["project"])
    #expect(model.isSelectedProjectArchived)
    #expect(model.toolbarTabs == [.info, .diff])
    deadline = Date().addingTimeInterval(5)
    while model.isLoadingProject && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.projectError == nil)
    #expect(model.selectedCommitID == oid)
    #expect(model.selectedCommitDiff == diff)
    #expect(model.projectReadme?.markdown == "# Project\n")
    #expect(model.openProjectURL(URL(string: "gitsync://project?name=space%20%26%20unicode%20%C3%A9")!))
    #expect(model.selectedProjectName == "space & unicode é")
}

@Test("archive restore targets the selected host", arguments: [false, true])
@MainActor
func archiveRestoreSelectedHost(remote: Bool) async throws {
    let host = SyncHost(machine: "pangolin", peer: "pangolin", root: "/projects", executable: "/unused")
    let item = try JSONDecoder().decode(BackupItem.self, from: Data("""
        {"name":"project","status":"archived","mirroredBy":[],
         "snapshots":[{"id":"source","machine":"source","branches":["main"],"syncMachines":[]}]}
        """.utf8))
    var received = false
    let model = AppModel(connectToHelper: false) { command in
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as! [String: Any]
        let restore = try #require(json["restoreBackup"] as? [String: Any])
        #expect(restore["hostID"] as? String == (remote ? host.id.uuidString : nil))
        received = true
        return EngineReply()
    }
    model.configuration.hosts = [host]
    model.selectedProjectName = item.name
    model.selectProjectHost(remote ? .host(host.id) : .local)
    model.unarchiveBackup(item, snapshot: item.snapshots[0])
    let deadline = Date().addingTimeInterval(2)
    while !received && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(received)
}

@Test("archive offers every present host regardless of the selected tab")
@MainActor
func archiveHostChoices() {
    let hosts = (0..<3).map { SyncHost(machine: "Peer \($0)", peer: "peer\($0)", root: "/projects", executable: "/unused") }
    let model = AppModel(connectToHelper: false)
    model.configuration = AppConfiguration(root: "/projects", machine: "Local", hosts: hosts,
        folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)],
        backupDestination: BackupDestinationConfiguration(root: "/backup"))
    model.selectedProjectName = "project"
    model.localProjects["project"] = PeerProject(name: "project", placement: .checkedOut)
    model.remoteProjects[hosts[0].id] = ["project": PeerProject(name: "project", placement: .mirrored)]
    model.remoteProjects[hosts[1].id] = ["project": PeerProject(name: "project", placement: .notPresent)]
    #expect(model.archiveHosts(for: "project") == [nil, hosts[0].id])
    #expect(model.canArchiveSelectedProject)
    model.localProjects["project"] = PeerProject(name: "project", placement: .notPresent)
    #expect(model.canArchiveSelectedProject)
    #expect(model.archiveHosts(for: "project") == [hosts[0].id])
    model.placementInProgress = "local"
    #expect(!model.canArchiveSelectedProject)
}

@Test("archive processes only chosen hosts and stops on failure", arguments: [false, true])
@MainActor
func archiveChosenHosts(fails: Bool) async {
    let hosts = (0..<3).map { SyncHost(machine: "Peer \($0)", peer: "peer\($0)", root: "/projects", executable: "/unused") }
    var received: [UUID?] = []
    let model = AppModel(connectToHelper: false) { command in
        guard case .setPlacement(let placement, let project, let hostID, _) = command else {
            Issue.record("Unexpected command")
            return EngineReply()
        }
        #expect(placement == .notPresent)
        #expect(project == "project")
        received.append(hostID)
        await Task.yield()
        return EngineReply(error: fails ? "Host unavailable" : nil)
    }
    model.configuration.hosts = hosts
    for host in hosts {
        model.remoteProjects[host.id] = ["project": PeerProject(name: "project", placement: .checkedOut)]
    }
    await model.archive("project", on: [])
    #expect(received.isEmpty)
    await model.archive("project", on: [hosts[0].id, hosts[2].id])
    #expect(received == (fails ? [hosts[0].id] : [hosts[0].id, hosts[2].id]))
    #expect(model.placementInProgress == nil)
    #expect(fails ? model.error?.contains("Host unavailable") == true : model.error == nil)
}
