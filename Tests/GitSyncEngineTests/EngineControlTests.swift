import Foundation
import Testing
@testable import GitSyncCore
@testable import GitSyncEngine

@Test("overlapping backup refreshes share a scan and publish its results")
@MainActor
func overlappingBackupRefreshes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("backup")
    try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
    _ = try Git.run(["init", "-q", "--bare", backup.appendingPathComponent("project.git").path])
    let model = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: AppConfiguration(root: root.path, machine: "test",
            backupDestination: BackupDestinationConfiguration(root: backup.path)),
        support: root.appendingPathComponent("support"))
    try model.loadBackupIndex()
    let scan = try #require(model.refreshBackupItems())
    for _ in 0..<20 {
        #expect(model.refreshBackupItems() == scan)
    }
    await scan.value
    #expect(model.backupError == nil)
    #expect(model.backupItems.map(\.name) == ["project"])
    _ = try Git.run(["init", "-q", "--bare", backup.appendingPathComponent("added.git").path])
    let next = try #require(model.refreshBackupItems())
    #expect(next != scan)
    await next.value
    #expect(model.backupItems.map(\.name) == ["project"])
    let refresh = try #require(model.refreshBackupItems())
    #expect(model.refreshBackupItems(refresh: true) == refresh)
    await refresh.value
    #expect(model.backupItems.map(\.name) == ["added", "project"])
}

@Test("archive completion publishes absence and refreshes the backup inventory while paused")
@MainActor
func archiveRefreshesInventory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    let backup = root.appendingPathComponent("backup")
    let support = root.appendingPathComponent("support")
    for directory in [source, backup, support] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let project = source.appendingPathComponent("project")
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-q", "--allow-empty", "-m", "Initial commit"])
    try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "test",
                     stateURL: root.appendingPathComponent("state.json"), bareDestination: true)
    let destination = BackupDestinationConfiguration(root: backup.path)
    let indexURL = support.appendingPathComponent("backup-index-\(destination.id.uuidString).json")
    try BackupIndex(url: indexURL).replaceCatalog(machine: "test", repositories: ["project"])
    let model = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                            configuration: AppConfiguration(root: source.path, machine: "test",
                                folders: [SyncFolder(name: "project", isLocal: true, availableLocally: true)],
                                backupDestination: destination), support: support)
    model.pause()
    try model.loadBackupIndex()
    var deadline = Date().addingTimeInterval(5)
    while model.backupItems.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(model.backupItems.first?.status == .mirrored)
    // Retry after the folder was removed, but before its absence reached the backup.
    try FileManager.default.removeItem(at: project)
    model.setPlacement(.notPresent, project: "project", hostID: nil)
    deadline = Date().addingTimeInterval(5)
    while model.placementInProgress != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error == nil)
    #expect(model.backupItems.first?.status == .archived)
    #expect(try BackupIndex(url: indexURL).items(in: backup).first?.status == .archived)
    #expect(model.placement(of: "project", on: nil) == .notPresent)

    let offline = root.appendingPathComponent("offline-backup")
    try FileManager.default.moveItem(at: backup, to: offline)
    try model.loadBackupIndex()
    deadline = Date().addingTimeInterval(5)
    while model.backupError == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.backupError != nil)
    #expect(model.backupItems.first?.status == .archived)
    model.setPlacement(.notPresent, project: "project", hostID: nil)
    #expect(model.error == "A current backup is required before removing the last host copy.")
    #expect(model.placementInProgress == nil)
    try FileManager.default.moveItem(at: offline, to: backup)
    try model.loadBackupIndex()
    deadline = Date().addingTimeInterval(5)
    while model.backupError != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.backupError == nil)
    #expect(model.backupItems.first?.status == .archived)
}

@Test("placement failures remain visible after restarting local sync")
@MainActor
func placementFailureSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-q", "--allow-empty", "-m", "Initial commit"])
    try Data("untracked\n".utf8).write(to: project.appendingPathComponent("README 2.md"))
    let model = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                            configuration: AppConfiguration(root: root.path, machine: "test"),
                            support: root.appendingPathComponent("support"))

    // Mirroring uses the same clean-checkout guard and recovery path as Archive.
    model.setPlacement(.mirrored, project: "project", hostID: nil)
    let deadline = Date().addingTimeInterval(5)
    while model.placementInProgress != nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.placementInProgress == nil)
    #expect(model.snapshot().error == "The checkout must be on a branch and completely clean.")
    #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("README 2.md").path))
}

@Test("event log counts only adjacent repeated events")
func eventLogCountsAdjacentRepeats() {
    #expect(countedEvents(["Fetch", "Fetch", "Idle", "Fetch"]) == [
        CountedEvent(message: "Fetch", count: 2),
        CountedEvent(message: "Idle"),
        CountedEvent(message: "Fetch"),
    ])
}

@Test("engine control requests round trip")
func engineControlRequestRoundTrip() throws {
    let request = EngineRequest(command: .addHost(
        peer: "atlas", root: "/srv/projects", executable: "git-sync",
        allowNameCollisions: false
    ))
    let decoded = try JSONDecoder().decode(
        EngineRequest.self,
        from: JSONEncoder().encode(request)
    )
    #expect(decoded.version == EngineControlProtocol.version)
    guard case let .addHost(peer, root, executable, allowNameCollisions) = decoded.command else {
        Issue.record("decoded the wrong command")
        return
    }
    #expect(peer == "atlas")
    #expect(root == "/srv/projects")
    #expect(executable == "git-sync")
    #expect(!allowNameCollisions)
}

@Test("global shortcut defaults on and persists toggles independently of repository setup")
@MainActor
func globalShortcutPreference() async throws {
    let suite = "GitSyncTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                            configuration: AppConfiguration(root: "", machine: "test"),
                            support: support, defaults: defaults)
    #expect(model.snapshot().globalShortcutEnabled)
    for enabled in [false, true, false] {
        let request = try JSONDecoder().decode(EngineRequest.self, from: JSONEncoder().encode(
            EngineRequest(command: .setGlobalShortcutEnabled(enabled))))
        let reply = await model.handle(request.command)
        #expect(reply.error == nil)
        let decoded = try JSONDecoder().decode(EngineReply.self, from: JSONEncoder().encode(reply))
        #expect(decoded.snapshot?.globalShortcutEnabled == enabled)
        let restarted = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                                    configuration: AppConfiguration(root: "", machine: "test"),
                                    support: support, defaults: defaults)
        #expect(restarted.globalShortcutEnabled == enabled)
    }
    #expect(!FileManager.default.fileExists(atPath: support.path))
}
