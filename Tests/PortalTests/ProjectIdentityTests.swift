import Foundation
import Testing
@testable import PortalCore

@Test("Reused names have independent UUID backups and restores retain identity")
func independentProjectIdentities() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let backups = root.appendingPathComponent("backups")
    let restores = root.appendingPathComponent("restores")
    for folder in [source, backups, restores] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func create() throws -> Repository {
        let url = source.appendingPathComponent("experiment")
        _ = try Git.run(["init", "-q", "-b", "main", url.path])
        _ = try Git.run(["-C", url.path, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "--allow-empty", "-m", UUID().uuidString])
        return Repository(name: "experiment", url: url)
    }
    let first = try create()
    let oldID = try first.projectID()
    let index = try BackupIndex(url: root.appendingPathComponent("index.json"))
    let state = root.appendingPathComponent("state.json")
    func sync() throws {
        let ids = try OneShot.sync(sourceRoot: source, destinationRoot: backups, machine: "Mac", stateURL: state, full: true, bareDestination: true)
        try index.replaceCatalog(machine: "Mac", repositories: ids)
    }
    try sync()
    try FileManager.default.moveItem(at: first.url, to: root.appendingPathComponent("previous"))
    let second = try create()
    let newID = try second.projectID()
    #expect(oldID != newID)
    try sync()
    let items = try index.items(in: backups, refresh: true)
    #expect(items.count == 2)
    #expect(items.allSatisfy { $0.name == "experiment" })
    let archived = try #require(items.first { $0.id == oldID })
    #expect(archived.status == .archived)
    #expect(items.first { $0.id == newID }?.status == .mirrored)
    try BackupIndex.restore(oldID, snapshotID: #require(archived.snapshots.first).id, from: backups, to: restores)
    #expect(try Repository(name: "experiment", url: restores.appendingPathComponent("experiment")).projectID() == oldID)
    try index.delete(oldID, in: backups)
    #expect(try index.items(in: backups).map(\.id) == [newID])
    #expect(throws: SyncError.self) {
        try OneShot.sync(sourceRoot: source, destinationRoot: restores, machine: "Mac", stateURL: root.appendingPathComponent("other.json"))
    }
}

@Test("Identity ordering migration preserves epoch and generations")
func identityOrderingMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = try StateStore(url: root.appendingPathComponent("state.json"))
    let id = UUID().uuidString.lowercased()
    let epoch = state.sourceEpoch
    let oid = String(repeating: "a", count: 40)
    _ = try state.updates(machine: "Mac", repository: "old", refs: ["refs/heads/main": oid], full: true)
    try state.accept(generation: 7, peer: "peer", epoch: epoch, repository: "old", ref: "refs/heads/main")
    try state.migrateIdentity(name: "old", id: id)
    try state.migrateIdentity(name: "old", id: id)
    #expect(state.sourceEpoch == epoch)
    #expect(try state.updates(machine: "Mac", repository: id, refs: ["refs/heads/main": oid], full: true).first?.generation == 1)
    #expect(state.acceptedGeneration(peer: "peer", epoch: epoch, repository: id, ref: "refs/heads/main") == 7)
}

@Test("Backup migration resumes after a directory move and never reuses its name mapping")
func resumableBackupIdentities() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backups = root.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
    let legacy = backups.appendingPathComponent("experiment.git")
    _ = try Git.run(["init", "--bare", legacy.path])
    let id = UUID().uuidString.lowercased()
    let manifest = root.appendingPathComponent("project-identities-v1.json")
    try JSONEncoder().encode(["experiment": id]).write(to: manifest)
    let indexURL = root.appendingPathComponent("index.json")
    try Data(#"{"catalogs":{"mac":{"machine":"Mac","repositories":["experiment"]}},"archived":[]}"#.utf8).write(to: indexURL)
    // Simulate interruption after the repository was moved, before catalog save.
    _ = try Repository(name: "experiment", url: legacy).projectID(adopting: id)
    _ = try Git.run(["-C", legacy.path, "config", "portal.projectName", "experiment"])
    try FileManager.default.moveItem(at: legacy, to: backups.appendingPathComponent(id + ".git"))
    let index = try BackupIndex(url: indexURL)
    let first = try #require(index.items(in: backups).first)
    #expect(first.id == id)
    #expect(first.name == "experiment")
    #expect(first.status == .mirrored)
    _ = try Git.run(["init", "--bare", legacy.path])
    let items = try index.items(in: backups, refresh: true)
    #expect(items.count == 2)
    #expect(Set(items.map(\.id)).count == 2)
    #expect(items.allSatisfy { $0.name == "experiment" })
}

@Test("Sync finds a restored project by UUID when its local folder name differs")
func renamedRestoreIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
    for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let source = try Repository.ensure(name: "original", in: a)
    let id = try source.projectID()
    let restored = try Repository.ensure(name: "restored", in: b, projectID: id)
    _ = try Git.run(["-C", source.url.path, "-c", "user.name=Test", "-c", "user.email=test@example.org", "commit", "--allow-empty", "-m", "initial"])
    try OneShot.sync(sourceRoot: a, destinationRoot: b, machine: "A", stateURL: root.appendingPathComponent("state.json"))
    #expect(!FileManager.default.fileExists(atPath: b.appendingPathComponent("original").path))
    #expect(try restored.projectID() == id)
    #expect(try Git.text(["-C", restored.url.path, "rev-parse", "refs/remotes/a/" + source.defaultBranch!]) == Git.text(["-C", source.url.path, "rev-parse", "HEAD"]))
}
