import Foundation
import Testing
@testable import PortalCore

private func renameRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("rename preserves dirty work and refuses stale sessions and old catalogs")
func projectRenamePreservesWork() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try Repository.ensure(name: "before", in: root)
    try Data("unsaved to Git".utf8).write(to: repository.url.appendingPathComponent("file"))
    let record = ProjectRename.Record(old: "before", new: "after")
    let original = try ProjectRename.records(in: root)
    try ProjectRename.perform(.prepare, record: record, in: root)
    #expect(throws: SyncError.self) { _ = try ProjectAccess(root: root, names: ["before"]) }
    #expect(throws: SyncError.self) { _ = try Repository.ensure(name: "after", in: root) }
    try ProjectRename.perform(.move, record: record, in: root)
    #expect(throws: SyncError.self) { _ = try ProjectAccess(root: root, names: ["after"]) }
    try ProjectRename.perform(.finish, record: record, in: root)
    #expect(try Repository.discover(in: root).map(\.name) == ["after"])
    #expect(try String(contentsOf: root.appendingPathComponent("after/file"), encoding: .utf8) == "unsaved to Git")
    #expect(throws: SyncError.self) { _ = try Repository.ensure(name: "before", in: root) }
    #expect(throws: SyncError.self) { _ = try ProjectAccess(root: root, expected: original) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("before").path))
}

@Test("busy operations and destination collisions prevent rename")
func projectRenameRefusesBusyAndCollisions() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Repository.ensure(name: "before", in: root)
    let record = ProjectRename.Record(old: "before", new: "after")
    do {
        let access = try ProjectAccess(root: root, names: ["before"])
        defer { withExtendedLifetime(access) {} }
        #expect(throws: SyncError.self) { try ProjectRename.perform(.prepare, record: record, in: root) }
    }
    try ProjectRename.perform(.prepare, record: record, in: root)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("after"), withIntermediateDirectories: false)
    #expect(throws: SyncError.self) { try ProjectRename.perform(.move, record: record, in: root) }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("before/.git").path))
    #expect(try !ProjectRename.records(in: root)[0].moved)
}

@Test("coordinator moves backup first and leaves partial failures suspended")
func projectRenameBackupFirst() throws {
    let backup = try renameRoot(), local = try renameRoot(), remote = try renameRoot()
    defer { for root in [backup, local, remote] { try? FileManager.default.removeItem(at: root) } }
    _ = try Repository.ensure(name: "before", in: backup, bare: true)
    _ = try Repository.ensure(name: "before", in: local)
    _ = try Repository.ensure(name: "before", in: remote)
    let index = try BackupIndex(url: backup.appendingPathComponent("index.json"))
    try index.replaceCatalog(machine: "mac", repositories: ["before"])
    let record = ProjectRename.Record(old: "before", new: "after")
    var moves: [String] = []
    let targets: [ProjectRename.Target] = [
        .init(name: "backup") { step in
            if step == .move { moves.append("backup") }
            try index.rename(record, step: step, in: backup)
        },
        .init(name: "local") { step in
            if step == .move { moves.append("local") }
            try ProjectRename.perform(step, record: record, in: local)
        },
        .init(name: "remote") { step in
            if step == .move { throw SyncError.disconnected }
            try ProjectRename.perform(step, record: record, in: remote)
        }
    ]
    #expect(throws: SyncError.self) { try ProjectRename.coordinate(targets) }
    #expect(moves == ["backup", "local"])
    #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("after.git").path))
    #expect(FileManager.default.fileExists(atPath: local.appendingPathComponent("after/.git").path))
    #expect(FileManager.default.fileExists(atPath: remote.appendingPathComponent("before/.git").path))
    let items = try index.items(in: backup, refresh: true)
    #expect(items.first?.name == "after")
    #expect(items.first?.mirroredBy == ["mac"])
    for root in [backup, local, remote] {
        #expect(throws: SyncError.self) { _ = try ProjectAccess(root: root, names: ["before", "after"]) }
    }
}

@Test("backup failure prevents every checkout move")
func projectRenameBackupFailure() throws {
    var movedLocal = false
    let targets: [ProjectRename.Target] = [
        .init(name: "backup") { if $0 == .move { throw SyncError.disconnected } },
        .init(name: "local") { if $0 == .move { movedLocal = true } }
    ]
    #expect(throws: SyncError.self) { try ProjectRename.coordinate(targets) }
    #expect(!movedLocal)
}

@Test("rename preserves source epoch and ref generations across restart")
func projectRenameStateMigration() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let stateURL = root.appendingPathComponent("state.json")
    let oid = String(repeating: "a", count: 40)
    var record = ProjectRename.Record(old: "before", new: "after")
    record.moved = true; record.complete = true
    var epoch = ""
    do {
        let state = try StateStore(url: stateURL)
        epoch = state.sourceEpoch
        _ = try state.updates(machine: "mac", repository: "before", refs: ["refs/heads/main": oid], full: true)
        _ = try state.accept(generation: 17, peer: "peer", epoch: epoch, repository: "before", ref: "refs/heads/main")
        try state.applyRenames([record])
        #expect(state.sourceEpoch == epoch)
        #expect(state.acceptedGeneration(peer: "peer", epoch: epoch, repository: "after", ref: "refs/heads/main") == 17)
    }
    let state = try StateStore(url: stateURL)
    try state.applyRenames([record])
    #expect(state.sourceEpoch == epoch)
    let updates = try state.updates(machine: "mac", repository: "after", refs: [:], full: false)
    #expect(updates.count == 1)
    #expect(updates.first?.generation == 2)
    #expect(updates.first?.oid == nil)
    #expect(state.acceptedGeneration(peer: "peer", epoch: epoch, repository: "after", ref: "refs/heads/main") == 17)
}

@Test("failed finish re-suspends previously finished hosts")
func projectRenameFinishFailure() throws {
    var localSuspended = false
    let targets: [ProjectRename.Target] = [
        .init(name: "local") { if $0 == .suspend { localSuspended = true } },
        .init(name: "peer") { if $0 == .finish { throw SyncError.disconnected } }
    ]
    #expect(throws: SyncError.self) { try ProjectRename.coordinate(targets) }
    #expect(localSuspended)
}

@Test("completed rename preserves project selections and repeated discovery")
func projectRenameConfiguration() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = UUID()
    var configuration = AppConfiguration(root: root.path, machine: "mac")
    configuration.folders = [SyncFolder(name: "before", isLocal: true, hosts: [host], availableLocally: true, availableHosts: [host])]
    let record = ProjectRename.Record(old: "before", new: "after")
    try ProjectRename.perform(.prepare, record: record, in: root)
    try configuration.discoverLocal([])
    #expect(configuration.folders.first?.name == "before")
    try ProjectRename.perform(.move, record: record, in: root)
    try ProjectRename.perform(.finish, record: record, in: root)
    try configuration.discoverLocal(["after"])
    try configuration.discoverLocal(["after"])
    #expect(configuration.folders.count == 1)
    #expect(configuration.folders.first?.name == "after")
    #expect(configuration.folders.first?.hosts == [host])
    #expect(configuration.folders.first?.isLocal == true)
}
