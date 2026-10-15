import Foundation
import Testing
@testable import PortalCore

private func renameRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test("cancelling rename during preflight leaves every journal untouched")
func projectRenameCancellationBeforePrepare() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = ProjectRename.Record(old: "before", new: "after")
    let operation = ProjectRename.Operation(id: record.id)
    #expect(throws: CancellationError.self) {
        try ProjectRename.coordinate([
            .init(name: "local") { try ProjectRename.perform($0, record: record, in: root) },
            .init(name: "peer") { step in
                #expect(step == .preflight)
                operation.cancel()
            }
        ], operation: operation)
    }
    #expect(try ProjectRename.records(in: root).isEmpty)
    #expect(operation.progress == .cancelling)
}

@Test("cancellation after preparation cannot interrupt the rename")
func projectRenameCancellationAfterPrepare() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = ProjectRename.Record(old: "before", new: "after")
    let operation = ProjectRename.Operation(id: record.id)
    try ProjectRename.coordinate([
        .init(name: "local") { step in
            if step == .prepare { operation.cancel() }
            try ProjectRename.perform(step, record: record, in: root)
        }
    ], operation: operation)
    #expect(operation.progress == .renaming)
    #expect(try ProjectRename.records(in: root).first?.complete == true)
}

@Test("an unwritable peer root does not suspend earlier roots")
func projectRenamePreflightsEveryRoot() throws {
    let backup = try renameRoot(), local = try renameRoot(), remote = try renameRoot()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: remote.path)
        for root in [backup, local, remote] { try? FileManager.default.removeItem(at: root) }
    }
    _ = try Repository.ensure(name: "before", in: backup, bare: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: remote.path)
    let record = ProjectRename.Record(old: "before", new: "after")
    #expect(throws: SyncError.self) {
        try ProjectRename.coordinate([
            .init(name: "backup") { try ProjectRename.perform($0, record: record, in: backup, bare: true) },
            .init(name: "local") { try ProjectRename.perform($0, record: record, in: local) },
            .init(name: "remote") { try ProjectRename.perform($0, record: record, in: remote) }
        ])
    }
    for root in [backup, local, remote] {
        #expect(try ProjectRename.records(in: root).isEmpty)
        #expect(throws: Never.self) { _ = try Repository.discover(in: root) }
    }
    #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("before.git").path))
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

@Test("a peer without preflight support cannot leave earlier roots suspended")
func projectRenameRejectsOldPeerBeforePrepare() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let record = ProjectRename.Record(old: "before", new: "after")
    var contactedSteps: [ProjectRename.Step] = []
    #expect(throws: SyncError.self) {
        try ProjectRename.coordinate([
            .init(name: "local") { try ProjectRename.perform($0, record: record, in: root) },
            .init(name: "old peer") { step in
                contactedSteps.append(step)
                throw SyncError.invalidProtocol("Unsupported rename request")
            }
        ])
    }
    #expect(contactedSteps == [.preflight])
    #expect(try ProjectRename.records(in: root).isEmpty)
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

@Test("sync after rename preserves peer refs and propagates branch deletion")
func projectRenameThenSync() throws {
    let root = try renameRoot(), source = try renameRoot(), backup = try renameRoot()
    defer { for directory in [root, source, backup] { try? FileManager.default.removeItem(at: directory) } }
    let repository = try Repository.ensure(name: "before", in: source)
    _ = try Git.run(["-C", repository.url.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "--allow-empty", "-qm", "initial"])
    _ = try Git.run(["-C", repository.url.path, "branch", "topic"])
    let stateURL = root.appendingPathComponent("state.json")
    _ = try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "mac", stateURL: stateURL,
                         full: true, bareDestination: true)
    let record = ProjectRename.Record(old: "before", new: "after")
    try ProjectRename.coordinate([
        .init(name: "backup") { try ProjectRename.perform($0, record: record, in: backup, bare: true) },
        .init(name: "source") { try ProjectRename.perform($0, record: record, in: source) }
    ])
    _ = try Git.run(["-C", source.appendingPathComponent("after").path, "branch", "-D", "topic"])
    _ = try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "mac", stateURL: stateURL,
                         bareDestination: true)
    let target = backup.appendingPathComponent("after.git")
    #expect(!Git.succeeds(["-C", target.path, "show-ref", "--verify", "refs/remotes/mac/topic"]))
    #expect(try !Git.text(["-C", target.path, "for-each-ref", "refs/sync/mac/expired/"]).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("before.git").path))
}

@Test("a live stale session cannot recreate the old project after rename")
func projectRenameRejectsStaleSession() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Repository.ensure(name: "before", in: root, bare: true)
    let incoming = Pipe(), outgoing = Pipe()
    let session = try SyncSession(root: root, machine: "backup", input: incoming.fileHandleForReading,
        output: outgoing.fileHandleForWriting, stateURL: root.appendingPathComponent("state.json"), receiveOnly: true)
    let finished = DispatchGroup()
    finished.enter()
    Thread.detachNewThread { defer { finished.leave() }; try? session.run() }
    defer { try? incoming.fileHandleForWriting.close() }
    let connection = FramedConnection(input: outgoing.fileHandleForReading, output: incoming.fileHandleForWriting)
    _ = try connection.receiveMessage()
    _ = try connection.receiveMessage()
    let record = ProjectRename.Record(old: "before", new: "after")
    for step in [ProjectRename.Step.prepare, .move, .finish] {
        try ProjectRename.perform(step, record: record, in: root, bare: true)
    }
    try connection.send(.hello("source", epoch: UUID().uuidString))
    try connection.send(.catalog(["before"]))
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("before.git").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("after.git").path))
}

@Test("read-only parent directories still allow ordinary discovery and sync guards")
func projectRenameReadOnlyParent() throws {
    let root = try renameRoot()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    _ = try Repository.ensure(name: "project", in: root)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    let access = try ProjectAccess(root: root, names: ["project"])
    #expect(try Repository.discover(in: root).map(\.name) == ["project"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["project"])
    withExtendedLifetime(access) {}
}

@Test("a vacated name can be reused without redirecting selections or mixing backup refs")
func projectRenameReusesVacatedName() throws {
    let source = try renameRoot(), backup = try renameRoot(), stateRoot = try renameRoot()
    defer { for root in [source, backup, stateRoot] { try? FileManager.default.removeItem(at: root) } }
    var tips: [String: String] = [:]
    for name in ["portal", "git-sync"] {
        let repository = try Repository.ensure(name: name, in: source)
        _ = try Git.run(["-C", repository.url.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                         "commit", "--allow-empty", "-qm", name])
        tips[name] = try Git.text(["-C", repository.url.path, "rev-parse", "HEAD"])
    }
    let stateURL = stateRoot.appendingPathComponent("state.json")
    _ = try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "mac", stateURL: stateURL,
                         full: true, bareDestination: true)
    let index = try BackupIndex(url: stateRoot.appendingPathComponent("index.json"))
    try index.replaceCatalog(machine: "mac", repositories: ["portal", "git-sync"])
    let host = UUID()
    var app = AppConfiguration(root: source.path, machine: "mac")
    app.folders = [SyncFolder(name: "portal", isLocal: true), SyncFolder(name: "git-sync", hosts: [host])]
    var connection = Configuration(root: source.path, machine: "mac", peer: "peer", remoteRoot: backup.path,
                                   repositories: ["git-sync"])
    let first = ProjectRename.Record(old: "portal", new: "portal-tty")
    let second = ProjectRename.Record(old: "git-sync", new: "portal", previousRenames: [first.id])
    for record in [first, second] {
        try ProjectRename.coordinate([
            .init(name: "backup") { try index.rename(record, step: $0, in: backup) },
            .init(name: "source") { try ProjectRename.perform($0, record: record, in: source) }
        ])
        try app.applyRenames()
        try connection.applyRenames(ProjectRename.records(in: source))
        _ = try OneShot.sync(sourceRoot: source, destinationRoot: backup, machine: "mac", stateURL: stateURL,
                             full: true, bareDestination: true)
    }
    app = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(app))
    connection = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(connection))
    try app.discoverLocal(["portal", "portal-tty"])
    try connection.applyRenames(ProjectRename.records(in: source))
    #expect(connection.repositories == ["portal"])
    #expect(app.folders.first(where: { $0.name == "portal" })?.hosts == [host])
    #expect(app.folders.first(where: { $0.name == "portal-tty" })?.hosts.isEmpty == true)
    #expect(Set(try Repository.discover(in: source).map(\.name)) == ["portal", "portal-tty"])
    for (name, old) in [("portal", "git-sync"), ("portal-tty", "portal")] {
        let refs = try Git.text(["-C", backup.appendingPathComponent(name + ".git").path,
                                 "for-each-ref", "--format=%(objectname)", "refs/remotes/mac/"])
        #expect(refs == tips[old])
    }
    let items = try index.items(in: backup, refresh: true)
    #expect(Set(items.map(\.name)) == ["portal", "portal-tty"])
    #expect(items.allSatisfy { $0.mirroredBy == ["mac"] })
    let revision = [first.id, second.id]
    #expect(throws: SyncError.self) { _ = try WireMessage.hello("peer", epoch: UUID().uuidString, namingRevision: [first.id]).validatedHello(expectedRevision: revision) }
    #expect(throws: Never.self) { _ = try WireMessage.hello("peer", epoch: UUID().uuidString, namingRevision: revision).validatedHello(expectedRevision: revision) }
    #expect(throws: SyncError.self) { try connection.applyRenames([]) }
    let state = try StateStore(url: stateURL)
    #expect(throws: SyncError.self) { try state.applyRenames([]) }
}

@Test("name reuse requires every destination to acknowledge the previous rename")
func projectRenameReuseRejectsStaleRoot() throws {
    let current = try renameRoot(), stale = try renameRoot()
    defer { for root in [current, stale] { try? FileManager.default.removeItem(at: root) } }
    let first = ProjectRename.Record(old: "portal", new: "portal-tty")
    try ProjectRename.coordinate([.init(name: "current") { try ProjectRename.perform($0, record: first, in: current) }])
    let second = ProjectRename.Record(old: "git-sync", new: "portal", previousRenames: [first.id])
    #expect(throws: SyncError.self) {
        try ProjectRename.coordinate([
            .init(name: "current") { try ProjectRename.perform($0, record: second, in: current) },
            .init(name: "stale") { try ProjectRename.perform($0, record: second, in: stale) }
        ])
    }
    #expect(try ProjectRename.records(in: current).map(\.id) == [first.id])
    #expect(try ProjectRename.records(in: stale).isEmpty)
    #expect(throws: SyncError.self) {
        _ = try OneShot.sync(sourceRoot: stale, destinationRoot: current, machine: "mac",
                             stateURL: stale.appendingPathComponent("state.json"), bareDestination: true)
    }
}

@Test("a reconnect with stale naming history cannot publish a reused name")
func projectRenameRejectsStaleReconnect() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = ProjectRename.Record(old: "portal", new: "portal-tty")
    let second = ProjectRename.Record(old: "git-sync", new: "portal", previousRenames: [first.id])
    for record in [first, second] {
        try ProjectRename.coordinate([.init(name: "backup") { try ProjectRename.perform($0, record: record, in: root, bare: true) }])
    }
    let incoming = Pipe(), outgoing = Pipe()
    let session = try SyncSession(root: root, machine: "backup", input: incoming.fileHandleForReading,
        output: outgoing.fileHandleForWriting, stateURL: root.appendingPathComponent("state.json"), receiveOnly: true,
        catalogObserver: { _, _ in Issue.record("Stale catalog must never be accepted") })
    let finished = DispatchGroup()
    finished.enter()
    Thread.detachNewThread { defer { finished.leave() }; try? session.run() }
    defer { try? incoming.fileHandleForWriting.close() }
    let connection = FramedConnection(input: outgoing.fileHandleForReading, output: incoming.fileHandleForWriting)
    let hello = try connection.receiveMessage()
    #expect(hello.namingRevision == [first.id, second.id])
    _ = try connection.receiveMessage()
    try connection.send(.hello("source", epoch: UUID().uuidString, namingRevision: [first.id]))
    try connection.send(.catalog(["portal"]))
    #expect(finished.wait(timeout: .now() + 5) == .success)
    #expect(try Repository.discover(in: root).isEmpty)
}

@Test("rename waits for a short backup write to release its root lock")
func projectRenameWaitsForBusyRoot() throws {
    let root = try renameRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let locked = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do {
            let access = try ProjectAccess(root: root)
            locked.signal()
            Thread.sleep(forTimeInterval: 0.2)
            withExtendedLifetime(access) {}
        } catch { Issue.record(error); locked.signal() }
        released.signal()
    }
    locked.wait()
    defer { released.wait() }
    let record = ProjectRename.Record(old: "before", new: "after")
    try ProjectRename.perform(.preflight, record: record, in: root)
    #expect(try ProjectRename.records(in: root).isEmpty)
}
