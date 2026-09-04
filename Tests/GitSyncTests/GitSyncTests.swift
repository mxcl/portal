import Foundation
import Testing
@testable import GitSyncCore
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

@Suite(.serialized)
struct GitSyncTests {

@Test("peer executable defaults to the installed app bundle")
func defaultPeerExecutable() {
    let configuration = Configuration(root: "/", machine: "mac", peer: "peer", remoteRoot: "/tmp")
    #expect(configuration.remoteExecutable == "/Applications/Git Sync.app/Contents/Resources/git-sync")
    #expect(configuration.syncCheckouts != true)
}

@Test("machine defaults to the macOS Computer Name")
func defaultMachineName() {
    #if canImport(SystemConfiguration)
    let computerName = SCDynamicStoreCopyComputerName(nil, nil)! as String
    #expect(Configuration.defaultMachine == Configuration.sanitizedMachine(computerName))
    #endif
}

@Test("git stdin finishes before process cleanup")
func gitInputWriterLifetime() throws {
    let input = Data(repeating: 0, count: 8 * 1024 * 1024)
    for _ in 0..<20 {
        _ = try Git.run(["--version"], input: input, allowFailure: true)
    }
}

@Test("a disconnected peer throws instead of terminating the helper")
func disconnectedPeerDoesNotSignal() throws {
    let pipe = Pipe()
    try pipe.fileHandleForReading.close()
    let connection = FramedConnection(input: .nullDevice, output: pipe.fileHandleForWriting)
    #expect(throws: (any Error).self) {
        try connection.send(.hello("test", epoch: UUID().uuidString))
    }
}

@Test("hello requires the current protocol and a source epoch")
func helloValidation() throws {
    let epoch = UUID().uuidString
    let hello = WireMessage.hello("test", epoch: epoch)
    let identity = try hello.validatedHello()
    #expect(identity.machine == "test")
    #expect(identity.epoch == epoch)

    var incompatible = hello
    incompatible.version = WireMessage.protocolVersion + 1
    #expect(throws: (any Error).self) { try incompatible.validatedHello() }

    var incomplete = hello
    incomplete.epoch = nil
    #expect(throws: (any Error).self) { try incomplete.validatedHello() }
}

@Test("transfer logs show direction and endpoints")
func transferLogs() {
    #expect(SyncSession.transferLog(sourceRef: "refs/heads/v4", machine: "pangolin",
                                    peer: "maliwan", isInitiator: false)
            == "refs/heads/v4 → pangolin")
    #expect(SyncSession.transferLog(sourceRef: "refs/heads/main", machine: "maliwan",
                                    peer: "pangolin", isInitiator: true)
            == "maliwan ← pangolin/refs/heads/main")
}

@Test("watcher timeout does not report a filesystem change")
func watcherTimeoutIsIdle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("git-sync-watch-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let watcher = Watcher(root: root, repositories: [])

    _ = watcher.wait(timeout: 0.1)
    #expect(!watcher.wait(timeout: 0.05))
}

}

private func git(_ arguments: [String], input: String? = nil) throws -> String {
    let process = Process(), output = Pipe(), error = Pipe(), stdin = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    process.standardOutput = output; process.standardError = error; process.standardInput = stdin
    try process.run()
    if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        throw SyncError.command(arguments, String(decoding: stderr, as: UTF8.self))
    }
    return String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class Fixture {
    let root: URL
    let a: URL
    let b: URL
    let state: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("git-sync-tests-\(UUID())")
        a = root.appendingPathComponent("A")
        b = root.appendingPathComponent("B")
        state = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main", a.appendingPathComponent("project").path])
        _ = try git(["-C", a.appendingPathComponent("project").path, "config", "user.name", "Test"])
        _ = try git(["-C", a.appendingPathComponent("project").path, "config", "user.email", "test@example.com"])
        try Data("one\n".utf8).write(to: a.appendingPathComponent("project/file.txt"))
        _ = try git(["-C", a.appendingPathComponent("project").path, "add", "file.txt"])
        _ = try git(["-C", a.appendingPathComponent("project").path, "commit", "-qm", "initial"])
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func cloneToB() throws {
        _ = try git(["clone", "-q", a.appendingPathComponent("project").path, b.appendingPathComponent("project").path])
    }
}

extension GitSyncTests {

@Test("repository snapshot exposes commits, refs, and README")
func repositorySnapshot() throws {
    let fixture = try Fixture()
    let repository = Repository(name: "project", url: fixture.a.appendingPathComponent("project"))
    let snapshot = try repository.snapshot()

    #expect(snapshot.commits.count == 1)
    #expect(snapshot.commits[0].subject == "initial")
    #expect(snapshot.head == "main")
    #expect(snapshot.branches == ["main"])
    #expect(snapshot.references.contains { $0.fullName == "refs/heads/main" })
    let content = RepositoryContent(snapshot: snapshot,
                                    readme: RepositoryReadme(markdown: "# Project", source: "HEAD"),
                                    githubURL: URL(string: "https://github.com/mxcl/git-sync"))
    #expect(try JSONDecoder().decode(RepositoryContent.self,
                                     from: JSONEncoder().encode(content)) == content)
    let diff = try repository.diff(at: snapshot.commits[0].oid)
    #expect(diff.contains("diff --git a/file.txt b/file.txt"))
    #expect(diff.contains("+one"))

    try Data("# Project\n\nHello.\n".utf8).write(to: repository.url.appendingPathComponent("README.md"))
    _ = try git(["-C", repository.url.path, "add", "README.md"])
    _ = try git(["-C", repository.url.path, "commit", "-qm", "readme"])
    #expect(repository.readme()?.markdown == "# Project\n\nHello.\n")
    #expect(repository.readme()?.source == "Checked out HEAD")
}

@Test("repository maps GitHub origins to project pages")
func githubOriginURL() throws {
    let expected = "https://github.com/mxcl/git-sync"
    for origin in [
        "git@github.com:mxcl/git-sync.git",
        "ssh://git@github.com/mxcl/git-sync.git",
        "https://github.com/mxcl/git-sync.git",
    ] {
        #expect(Repository.githubURL(forOrigin: origin)?.absoluteString == expected)
    }
    #expect(Repository.githubURL(forOrigin: "git@gitlab.com:mxcl/git-sync.git") == nil)

    let fixture = try Fixture()
    let repository = Repository(name: "project", url: fixture.a.appendingPathComponent("project"))
    _ = try git(["-C", repository.url.path, "remote", "add", "origin", "git@github.com:mxcl/git-sync.git"])
    #expect(repository.githubURL?.absoluteString == expected)
}

@Test("a mirrored project can create a checkout from a peer branch")
func mirroredProjectCreatesCheckout() throws {
    let fixture = try Fixture()
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state)
    let project = fixture.b.appendingPathComponent("project")

    #expect(Repository(name: "project", url: project).placement == .mirrored)
    let repository = try Repository.setPlacement(name: "project", in: fixture.b,
                                                  to: .checkedOut, branch: "main")

    #expect(repository.placement == .checkedOut)
    #expect(try String(contentsOf: project.appendingPathComponent("file.txt"), encoding: .utf8) == "one\n")
}

@Test("ordinary commit copies objects without touching checkout state")
func ordinaryCommitSafety() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let source = fixture.a.appendingPathComponent("project")
    let destination = fixture.b.appendingPathComponent("project")
    let localMain = try git(["-C", destination.path, "rev-parse", "refs/heads/main"])
    let localHead = try git(["-C", destination.path, "symbolic-ref", "HEAD"])
    let localIndex = try git(["-C", destination.path, "write-tree"])
    let localFile = try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8)

    try Data("two\n".utf8).write(to: source.appendingPathComponent("file.txt"))
    _ = try git(["-C", source.path, "add", "file.txt"])
    _ = try git(["-C", source.path, "commit", "-qm", "second"])
    let remoteMain = try git(["-C", source.path, "rev-parse", "main"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)

    #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"]) == remoteMain)
    #expect(try git(["-C", destination.path, "rev-parse", "refs/heads/main"]) == localMain)
    #expect(try git(["-C", destination.path, "symbolic-ref", "HEAD"]) == localHead)
    #expect(try git(["-C", destination.path, "write-tree"]) == localIndex)
    #expect(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8) == localFile)
    #expect(try git(["-C", destination.path, "status", "--porcelain"]).isEmpty)
    #expect(try git(["-C", destination.path, "cat-file", "-t", remoteMain]) == "commit")
}

@Test("opt-in fast-forwards matching clean checkouts")
func matchingCleanCheckoutsFollowUpdates() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let source = fixture.a.appendingPathComponent("project")
    let destination = fixture.b.appendingPathComponent("project")
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state, syncCheckouts: true)

    for number in 2...3 {
        try Data("\(number)\n".utf8).write(to: source.appendingPathComponent("file.txt"))
        _ = try git(["-C", source.path, "commit", "-qam", "commit \(number)"])
    }
    let expected = try git(["-C", source.path, "rev-parse", "main"])

    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state, syncCheckouts: true)

    #expect(try git(["-C", destination.path, "rev-parse", "main"]) == expected)
    #expect(try git(["-C", destination.path, "status", "--porcelain"]).isEmpty)
    #expect(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8) == "3\n")
}

@Test("clean checkouts catch up after an earlier update was blocked")
func cleanCheckoutsRetryBlockedUpdates() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let source = fixture.a.appendingPathComponent("project")
    let destination = fixture.b.appendingPathComponent("project")
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state, syncCheckouts: true)

    try Data("local dirt\n".utf8).write(to: destination.appendingPathComponent("file.txt"))
    try Data("remote\n".utf8).write(to: source.appendingPathComponent("file.txt"))
    _ = try git(["-C", source.path, "commit", "-qam", "remote"])
    let expected = try git(["-C", source.path, "rev-parse", "main"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state, syncCheckouts: true)

    _ = try git(["-C", destination.path, "restore", "file.txt"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state, full: true, syncCheckouts: true)

    #expect(try git(["-C", destination.path, "rev-parse", "main"]) == expected)
}

@Test("local staged, unstaged, or committed changes invalidate checkout syncing")
func localChangesStopCheckoutUpdates() throws {
    func check(_ change: String) throws {
        let fixture = try Fixture(); try fixture.cloneToB()
        let source = fixture.a.appendingPathComponent("project")
        let destination = fixture.b.appendingPathComponent("project")
        try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                         machine: "A", stateURL: fixture.state, syncCheckouts: true)

        try Data("local \(change)\n".utf8).write(to: destination.appendingPathComponent("file.txt"))
        if change != "unstaged" { _ = try git(["-C", destination.path, "add", "file.txt"]) }
        if change == "committed" {
            _ = try git(["-C", destination.path, "-c", "user.name=Test", "-c",
                         "user.email=test@example.com", "commit", "-qm", "local"])
        }
        let localTip = try git(["-C", destination.path, "rev-parse", "main"])
        try Data("remote\n".utf8).write(to: source.appendingPathComponent("file.txt"))
        _ = try git(["-C", source.path, "commit", "-qam", "remote"])
        let remoteTip = try git(["-C", source.path, "rev-parse", "main"])

        try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                         machine: "A", stateURL: fixture.state, syncCheckouts: true)

        #expect(try git(["-C", destination.path, "rev-parse", "main"]) == localTip,
                "\(change) checkout moved")
        #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"]) == remoteTip)
    }

    for change in ["unstaged", "staged", "committed"] { try check(change) }
}

@Test("missing projects are initialized without a checkout")
func createsMissingProject() throws {
    let fixture = try Fixture()
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)
    let destination = fixture.b.appendingPathComponent("project")
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("file.txt").path))
    #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"]) == git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"]))
}

@Test("backup projects are stored as bare dot-git directories")
func createsBareBackupProject() throws {
    let fixture = try Fixture()
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A",
                     stateURL: fixture.state, bareDestination: true)
    let destination = fixture.b.appendingPathComponent("project.git")
    #expect(try git(["-C", destination.path, "rev-parse", "--is-bare-repository"]) == "true")
    #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"])
            == git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"]))
    #expect(!FileManager.default.fileExists(atPath: fixture.b.appendingPathComponent("project").path))
}

@Test("branch deletion retains a tombstone")
func deletionTombstone() throws {
    let fixture = try Fixture()
    let source = fixture.a.appendingPathComponent("project")
    _ = try git(["-C", source.path, "branch", "feature"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)
    _ = try git(["-C", source.path, "branch", "-D", "feature"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)
    let destination = fixture.b.appendingPathComponent("project")
    #expect((try? git(["-C", destination.path, "rev-parse", "--verify", "refs/remotes/a/feature"])) == nil)
    let expired = try git(["-C", destination.path, "for-each-ref", "--format=%(refname)", "refs/sync/A/expired"])
    #expect(!expired.split(separator: "\n").isEmpty)
}

@Test("full one-shot repairs a missing backup ref")
func fullOneShotRepairsMissingRef() throws {
    let fixture = try Fixture()
    let destination = fixture.b.appendingPathComponent("project")
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state)
    let expected = try git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"])
    _ = try git(["-C", destination.path, "update-ref", "-d", "refs/remotes/a/main"])

    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b,
                     machine: "A", stateURL: fixture.state, full: true)

    #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"]) == expected)
}

@Test("receiver rejects unsafe ref paths and corrupt packs")
func rejectsUnsafeInput() throws {
    let fixture = try Fixture()
    let repository = try Repository.ensure(name: "project", in: fixture.b)
    let writer = try PeerRefWriter(repository: repository, peer: "A")
    for ref in ["HEAD", "refs/remotes/origin/main", "../something", "refs/heads/../main"] {
        #expect(throws: (any Error).self) { try writer.destinationRef(ref) }
    }
    #expect(throws: (any Error).self) {
        try repository.install(pack: Data("not a pack".utf8), target: String(repeating: "a", count: 40))
    }
    #expect(try git(["-C", repository.url.path, "for-each-ref", "--format=%(refname)"]).isEmpty)
}

@Test("stale generation remains distinguishable")
func generationsPersist() throws {
    let fixture = try Fixture()
    let epoch: String
    do {
        let store = try StateStore(url: fixture.state)
        epoch = store.sourceEpoch
        try store.accept(generation: 2, peer: "A", epoch: epoch,
                         repository: "project", ref: "refs/heads/main")
        #expect(try !store.accept(generation: 1, peer: "A", epoch: epoch,
                                 repository: "project", ref: "refs/heads/main"))
        #expect(store.acceptedGeneration(peer: "A", epoch: epoch,
                                        repository: "project", ref: "refs/heads/main") == 2)
    }
    let reopened = try StateStore(url: fixture.state)
    #expect(reopened.sourceEpoch == epoch)
    #expect(reopened.acceptedGeneration(peer: "A", epoch: epoch,
                                        repository: "project", ref: "refs/heads/main") == 2)
}

@Test("a new source epoch does not inherit stale generations")
func sourceEpochResetsGenerationNamespace() throws {
    let fixture = try Fixture()
    let store = try StateStore(url: fixture.state)
    let oldEpoch = UUID().uuidString
    let newEpoch = UUID().uuidString
    try store.accept(generation: 9, peer: "A", epoch: oldEpoch,
                     repository: "project", ref: "refs/heads/main")
    #expect(store.acceptedGeneration(peer: "A", epoch: newEpoch,
                                    repository: "project", ref: "refs/heads/main") == 0)
}

@Test("state has one writer")
func stateHasOneWriter() throws {
    let fixture = try Fixture()
    let first = try StateStore(url: fixture.state)
    #expect(throws: (any Error).self) { try StateStore(url: fixture.state) }
    withExtendedLifetime(first) {}
}

@Test("preflight returns only sorted repository name matches")
func preflightOverlap() {
    #expect(Runner.overlap(local: ["z", "shared", "a", "shādoe"],
                          remote: ["shared", "other", "a", "shādoe"]) == ["a", "shared", "shādoe"])
}

@Test("backup preflight requires a writable existing destination")
func backupPreflight() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("git-sync-backup-preflight-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(throws: (any Error).self) { try Runner.prepareBackup(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Runner.prepareBackup(at: root)

    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test("backup preflight migrates legacy empty wrappers")
func backupDestinationMigration() throws {
    let fixture = try Fixture()
    let legacy = try Repository.ensure(name: "legacy", in: fixture.b)
    let checkout = try Repository.ensure(name: "checkout", in: fixture.b)
    try Data("keep\n".utf8).write(to: checkout.url.appendingPathComponent("file.txt"))
    _ = try git(["-C", legacy.url.path, "fetch", fixture.a.appendingPathComponent("project").path,
                 "main:refs/remotes/a/main"])

    try Runner.prepareBackup(at: fixture.b)

    let migrated = fixture.b.appendingPathComponent("legacy.git")
    #expect(!FileManager.default.fileExists(atPath: legacy.url.path))
    #expect(try git(["-C", migrated.path, "rev-parse", "--is-bare-repository"]) == "true")
    #expect(try git(["-C", migrated.path, "rev-parse", "refs/remotes/a/main"])
            == git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"]))
    #expect(FileManager.default.fileExists(atPath: checkout.url.appendingPathComponent(".git").path))
}

@Test("backup index classifies and archives repositories from complete host catalogs")
func backupArchiveClassification() throws {
    let fixture = try Fixture()
    let indexURL = fixture.root.appendingPathComponent("backup-index.json")
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A",
                     stateURL: fixture.state, bareDestination: true)
    let index = try BackupIndex(url: indexURL)

    #expect(try index.items(in: fixture.b).first?.status == .unknown)
    try index.replaceCatalog(machine: "A", repositories: ["project"])
    #expect(try index.items(in: fixture.b).first?.status == .mirrored)

    try index.replaceCatalog(machine: "A", repositories: [])
    #expect(try index.items(in: fixture.b).first?.status == .archived)
    try index.archive("project", in: fixture.b)
    #expect(try index.items(in: fixture.b).first?.status == .archived)

    try index.replaceCatalog(machine: "A", repositories: ["project"])
    #expect(try index.items(in: fixture.b).first?.status == .mirrored)
    #expect(try BackupIndex(url: indexURL).items(in: fixture.b).first?.status == .mirrored)
}

@Test("unarchive restores one snapshot onto this host without losing peer history")
func unarchiveOntoThisHost() throws {
    let fixture = try Fixture()
    let source = fixture.a.appendingPathComponent("project")
    _ = try git(["-C", source.path, "branch", "feature"])
    _ = try git(["-C", source.path, "tag", "v1"])
    try Data("# Archived Project\n".utf8).write(to: source.appendingPathComponent("README.md"))
    _ = try git(["-C", source.path, "add", "README.md"])
    _ = try git(["-C", source.path, "commit", "-qm", "readme"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A",
                     stateURL: fixture.state, bareDestination: true)
    let backup = fixture.b.appendingPathComponent("project.git")
    let tip = try git(["-C", backup.path, "rev-parse", "refs/remotes/a/main"])
    _ = try git(["-C", backup.path, "update-ref", "refs/heads/backup-only", tip])
    _ = try git(["-C", backup.path, "update-ref", "refs/remotes/b/peer", tip])
    let restoreRoot = fixture.root.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
    let index = try BackupIndex(url: fixture.root.appendingPathComponent("backup-index.json"))
    try index.replaceCatalog(machine: "A", repositories: [])
    let item = try #require(index.items(in: fixture.b).first)
    let snapshot = try #require(item.snapshots.first { $0.machine == "A" })

    let content = try BackupIndex.content(item.name, snapshotID: snapshot.id, from: fixture.b)
    #expect(content.snapshot.head == "main")
    #expect(content.snapshot.branches == ["feature", "main"])
    #expect(content.snapshot.references.contains { $0.fullName == "refs/heads/main" })
    #expect(content.snapshot.references.contains { $0.fullName == "refs/tags/v1" })
    #expect(content.snapshot.references.contains { $0.fullName == "refs/remotes/b/peer" })
    #expect(!content.snapshot.references.contains { $0.fullName == "refs/heads/backup-only" })
    #expect(content.readme?.markdown == "# Archived Project\n")
    #expect(try BackupIndex.diff(item.name, snapshotID: snapshot.id,
                                 oid: content.snapshot.commits[0].oid, from: fixture.b).contains("README.md"))
    #expect(throws: (any Error).self) {
        try BackupIndex.content(item.name, snapshotID: "missing", from: fixture.b)
    }
    #expect(throws: (any Error).self) {
        try BackupIndex.diff(item.name, snapshotID: snapshot.id, oid: "HEAD", from: fixture.b)
    }

    try BackupIndex.restore(item.name, snapshotID: snapshot.id, from: fixture.b, to: restoreRoot)

    let restored = restoreRoot.appendingPathComponent("project")
    #expect(try git(["-C", restored.path, "rev-parse", "main"])
            == git(["-C", source.path, "rev-parse", "main"]))
    #expect(try git(["-C", restored.path, "rev-parse", "feature"])
            == git(["-C", source.path, "rev-parse", "feature"]))
    #expect(try git(["-C", restored.path, "rev-parse", "v1"])
            == git(["-C", source.path, "rev-parse", "v1"]))
    #expect(try String(contentsOf: restored.appendingPathComponent("file.txt"), encoding: .utf8) == "one\n")
    #expect(throws: (any Error).self) {
        try BackupIndex.restore(item.name, snapshotID: snapshot.id, from: fixture.b, to: restoreRoot)
    }
}

@Test("archived bare branches remain restorable")
func archivedBareBranchesRemainRestorable() throws {
    let fixture = try Fixture()
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A",
                     stateURL: fixture.state, bareDestination: true)
    let repository = fixture.b.appendingPathComponent("project.git")
    let tip = try git(["-C", repository.path, "rev-parse", "refs/remotes/a/main"])
    _ = try git(["-C", repository.path, "update-ref", "refs/heads/main", tip])
    _ = try git(["-C", repository.path, "update-ref", "refs/tags/v1", tip])
    _ = try git(["-C", repository.path, "update-ref", "refs/stash", tip])
    _ = try git(["-C", repository.path, "update-ref", "-d", "refs/remotes/a/main"])

    let index = try BackupIndex(url: fixture.root.appendingPathComponent("backup-index.json"))
    try index.replaceCatalog(machine: "A", repositories: [])
    try index.archive("project", in: fixture.b)
    let item = try #require(index.items(in: fixture.b).first)
    #expect(item.status == .archived)
    let snapshot = try #require(item.snapshots.first { $0.machine == "Stored backup" })
    #expect(snapshot.branches == ["main"])
    let content = try BackupIndex.content(item.name, snapshotID: snapshot.id, from: fixture.b)
    #expect(content.snapshot.head == "main")
    #expect(content.snapshot.branches == ["main"])
    #expect(content.snapshot.references.contains { $0.fullName == "refs/tags/v1" })
    let restoreRoot = fixture.root.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
    let bundle = fixture.root.appendingPathComponent("stored.bundle")

    try BackupIndex.exportBundle(item.name, snapshotID: snapshot.id,
                                 from: fixture.b, to: bundle)
    try BackupIndex.restore(item.name, snapshot: snapshot, from: bundle, to: restoreRoot)

    #expect(try git(["-C", restoreRoot.appendingPathComponent("project").path,
                     "rev-parse", "main"]) == tip)
    #expect(try git(["-C", restoreRoot.appendingPathComponent("project").path,
                     "rev-parse", "v1"]) == tip)
    #expect(try git(["-C", restoreRoot.appendingPathComponent("project").path,
                     "rev-parse", "refs/stash"]) == tip)
}

@Test("local backup socket is owner-only and identifies sessions")
func localBackupSocket() throws {
    let root = URL(fileURLWithPath: "/tmp/gs-\(UUID())")
    let socket = root.appendingPathComponent("receiver.sock")
    defer { try? FileManager.default.removeItem(at: root) }

    let listener = try LocalBackupListener(url: socket)
    defer { listener.close() }
    let client = try LocalBackupTransport.connect(mode: LocalBackupTransport.session, to: socket)
    defer { try? client.close() }
    let server = try listener.accept()
    defer { try? server.close() }

    #expect(try LocalBackupTransport.mode(from: server) == LocalBackupTransport.session)
    #expect((try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    try client.write(contentsOf: Data("ping".utf8))
    #expect(try server.read(upToCount: 4) == Data("ping".utf8))
    try server.write(contentsOf: Data("pong".utf8))
    #expect(try client.read(upToCount: 4) == Data("pong".utf8))
}

@Test("backup control lists, archives, and exports a restorable snapshot")
func backupControl() throws {
    let fixture = try Fixture()
    let largeReadme = String(repeating: "x", count: 1_100_000)
    try Data(largeReadme.utf8).write(to: fixture.a.appendingPathComponent("project/README.md"))
    _ = try git(["-C", fixture.a.appendingPathComponent("project").path, "add", "README.md"])
    _ = try git(["-C", fixture.a.appendingPathComponent("project").path, "commit", "-qm", "large readme"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A",
                     stateURL: fixture.state, bareDestination: true)
    let index = try BackupIndex(url: fixture.root.appendingPathComponent("backup-index.json"))
    try index.replaceCatalog(machine: "A", repositories: [])
    let socketRoot = URL(fileURLWithPath: "/tmp/gs-control-\(UUID())")
    let socket = socketRoot.appendingPathComponent("control.sock")
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let listener = try LocalBackupListener(url: socket)
    defer { listener.close() }

    func request(_ request: BackupControlRequest, exportTo bundle: URL? = nil) throws
        -> BackupControlResponse {
        let client = try LocalBackupTransport.connect(mode: LocalBackupTransport.session, to: socket)
        defer { try? client.close() }
        DispatchQueue.global().async {
            guard let server = try? listener.accept() else { return }
            defer { try? server.close() }
            guard (try? LocalBackupTransport.mode(from: server)) == LocalBackupTransport.session else { return }
            try? BackupControlService.serve(server, root: fixture.b, index: index)
        }
        try BackupControlConnection.send(request, to: client)
        let response = try BackupControlConnection.receive(BackupControlResponse.self, from: client).checked()
        if let bundle, let count = response.byteCount {
            #expect(FileManager.default.createFile(atPath: bundle.path, contents: nil))
            let output = try FileHandle(forWritingTo: bundle)
            defer { try? output.close() }
            try BackupControlConnection.copy(count, from: client, to: output)
        }
        return response
    }

    func requestPayload(_ request: BackupControlRequest) throws -> Data {
        let client = try LocalBackupTransport.connect(mode: LocalBackupTransport.session, to: socket)
        defer { try? client.close() }
        DispatchQueue.global().async {
            guard let server = try? listener.accept() else { return }
            defer { try? server.close() }
            guard (try? LocalBackupTransport.mode(from: server)) == LocalBackupTransport.session else { return }
            try? BackupControlService.serve(server, root: fixture.b, index: index)
        }
        try BackupControlConnection.send(request, to: client)
        let response = try BackupControlConnection.receive(BackupControlResponse.self, from: client).checked()
        return try BackupControlConnection.receivePayload(try #require(response.byteCount), from: client)
    }

    let candidate = try #require(request(BackupControlRequest(action: .list)).items?.first)
    #expect(candidate.status == .archived)
    #expect(throws: (any Error).self) {
        try request(BackupControlRequest(version: 0, action: .list))
    }
    _ = try request(BackupControlRequest(action: .archive, repository: candidate.name))
    #expect(try request(BackupControlRequest(action: .list)).items?.first?.status == .archived)

    let bundle = fixture.root.appendingPathComponent("export.bundle")
    let snapshot = try #require(candidate.snapshots.first)
    let contentData = try requestPayload(BackupControlRequest(
        action: .content, repository: candidate.name, snapshotID: snapshot.id
    ))
    #expect(contentData.count > 1_048_576)
    let content = try JSONDecoder().decode(RepositoryContent.self, from: contentData)
    #expect(content.readme?.markdown == largeReadme)
    let commit = try #require(content.snapshot.commits.first)
    let diff = try requestPayload(BackupControlRequest(
        action: .diff, repository: candidate.name, snapshotID: snapshot.id, oid: commit.oid
    ))
    #expect(diff.count > 1_048_576)
    _ = try request(BackupControlRequest(action: .export, repository: candidate.name,
                                         snapshotID: snapshot.id), exportTo: bundle)
    let restored = fixture.root.appendingPathComponent("restored")
    try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
    try BackupIndex.restore(candidate.name, snapshot: snapshot, from: bundle, to: restored)
    #expect(try git(["-C", restored.appendingPathComponent("project").path, "rev-parse", "main"])
            == git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"]))
    _ = try request(BackupControlRequest(action: .catalog, machine: "A", repositories: ["project"]))
    #expect(try request(BackupControlRequest(action: .list)).items?.first?.status == .mirrored)
}

@Test("app-owned backups do not require a remote filesystem path")
func appOwnedBackupConfiguration() throws {
    let configuration = Configuration(root: "/", machine: "A", peer: "b", remoteRoot: "",
                                      remoteReceiveOnly: true)
    try configuration.validate()
}

@Test("managed Git remotes share the peer ref namespaces")
func managedGitRemote() throws {
    let fixture = try Fixture()
    let repository = try #require(Repository.discover(in: fixture.a).first)
    let peer = PeerRepositoryLocation(machine: "My_Peer.local", sshTarget: "b.example", root: "~/src")

    try repository.configureRemote(peer)

    #expect(try git(["-C", repository.url.path, "remote", "get-url", "my-peer-local"])
            == "b.example:~/src/project")
    #expect(try git(["-C", repository.url.path, "config", "--get-all", "remote.my-peer-local.fetch"])
            == "+refs/heads/*:refs/remotes/my-peer-local/*\n+refs/tags/*:refs/sync/My_Peer.local/tags/*")
    #expect(try git(["-C", repository.url.path, "config", "--get", "remote.my-peer-local.tagOpt"]) == "--no-tags")
    #expect(try git(["-C", repository.url.path, "config", "--get", "remote.my-peer-local.prune"]) == "true")

    try repository.configureRemote(PeerRepositoryLocation(machine: "My_Peer.local", sshTarget: "new-b", root: "/code/"))
    #expect(try git(["-C", repository.url.path, "remote", "get-url", "my-peer-local"])
            == "new-b:/code/project")
}

@Test("host discovery prepopulates locations but sync requires both hosts")
func hostDiscoverySelection() throws {
    var configuration = AppConfiguration(root: "/tmp", machine: "A")
    try configuration.discoverLocal(["local", "shared"])
    let host = SyncHost(machine: "B", peer: "b", root: "/tmp")

    let matches = try configuration.addHost(host, repositories: ["remote", "shared"])

    #expect(matches == ["shared"])
    #expect(configuration.repositories(for: host.id) == ["shared"])
    let remote = try #require(configuration.folders.first { $0.name == "remote" })
    #expect(!remote.isLocal)
    #expect(remote.hosts == [host.id])

    configuration.folders[configuration.folders.firstIndex { $0.name == "remote" }!].isLocal = true
    #expect(configuration.repositories(for: host.id) == ["remote", "shared"])
    configuration.folders[configuration.folders.firstIndex { $0.name == "shared" }!].hosts.remove(host.id)
    #expect(configuration.repositories(for: host.id) == ["remote"])

    try configuration.updateHostIdentity(host.id, machine: "Pangolin")
    #expect(configuration.hosts.first?.machine == "Pangolin")

    try configuration.renameHost(host.id, name: " Atlas ")
    #expect(configuration.hosts.first?.name == "Atlas")
    #expect(configuration.hosts.first?.machine == "Pangolin")

    #expect(throws: (any Error).self) {
        try configuration.renameHost(host.id, name: "  ")
    }

    #expect(throws: (any Error).self) {
        try configuration.addHost(SyncHost(machine: "A", peer: "self", root: "/tmp"), repositories: [])
    }
}

@Test("backup uses an existing host and this Mac owns a distinct destination")
func backupConfigurationValidation() throws {
    let host = SyncHost(machine: "B", peer: "b", root: "/srv/repos")
    var configuration = AppConfiguration(root: "/tmp", machine: "A", hosts: [host])

    configuration.backup = BackupConfiguration(hostID: host.id)
    #expect(try configuration.backupHost() == host)

    configuration.backup = BackupConfiguration(hostID: UUID())
    #expect(throws: (any Error).self) { try configuration.backupHost() }

    configuration.backup = BackupConfiguration(hostID: host.id)
    configuration.removeHost(host.id)
    #expect(configuration.backup == nil)

    configuration.backupDestination = BackupDestinationConfiguration(root: "/tmp/")
    #expect(throws: (any Error).self) { try configuration.validatedBackupDestination() }
    configuration.backupDestination = BackupDestinationConfiguration(root: "/srv/backup")
    #expect(try configuration.validatedBackupDestination()?.path == "/srv/backup")
}

@Test("configuration without backup settings still decodes")
func legacyAppConfigurationDecoding() throws {
    let data = Data(#"{"root":"/tmp","machine":"A","hosts":[{"id":"00000000-0000-0000-0000-000000000001","machine":"B","peer":"b","root":"/tmp","executable":"git-sync"}],"folders":[]}"#.utf8)
    let configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
    #expect(configuration.hosts.first?.name == "B")
    #expect(configuration.backup == nil)
    #expect(configuration.backupDestination == nil)
    #expect(configuration.syncCheckouts != true)
}

@Test("local discovery removes deleted local-only folders")
func localDiscoveryRemovesDeletedFolders() throws {
    var configuration = AppConfiguration(root: "/tmp", machine: "A")
    try configuration.discoverLocal(["deleted", "shared"])
    let host = SyncHost(machine: "B", peer: "b", root: "/tmp")
    try configuration.addHost(host, repositories: ["shared"])

    try configuration.discoverLocal([])

    #expect(configuration.folders.map(\.name) == ["shared"])
    #expect(configuration.folders.first?.availableLocally == false)
}

@Test("divergent branches remain independent and available on both machines")
func divergentBranches() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let a = fixture.a.appendingPathComponent("project"), b = fixture.b.appendingPathComponent("project")
    _ = try git(["-C", b.path, "config", "user.name", "Test"])
    _ = try git(["-C", b.path, "config", "user.email", "test@example.com"])
    try Data("from A\n".utf8).write(to: a.appendingPathComponent("a.txt"))
    _ = try git(["-C", a.path, "add", "a.txt"]); _ = try git(["-C", a.path, "commit", "-qm", "A"])
    try Data("from B\n".utf8).write(to: b.appendingPathComponent("b.txt"))
    _ = try git(["-C", b.path, "add", "b.txt"]); _ = try git(["-C", b.path, "commit", "-qm", "B"])
    let aMain = try git(["-C", a.path, "rev-parse", "main"]), bMain = try git(["-C", b.path, "rev-parse", "main"])

    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.root.appendingPathComponent("A-state"))
    try OneShot.sync(sourceRoot: fixture.b, destinationRoot: fixture.a, machine: "B", stateURL: fixture.root.appendingPathComponent("B-state"))

    #expect(try git(["-C", a.path, "rev-parse", "main"]) == aMain)
    #expect(try git(["-C", b.path, "rev-parse", "main"]) == bMain)
    #expect(try git(["-C", a.path, "rev-parse", "refs/remotes/b/main"]) == bMain)
    #expect(try git(["-C", b.path, "rev-parse", "refs/remotes/a/main"]) == aMain)
}

@Test("force update moves only the peer ref")
func forceUpdate() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let a = fixture.a.appendingPathComponent("project"), b = fixture.b.appendingPathComponent("project")
    let state = fixture.root.appendingPathComponent("force-state")
    let initial = try git(["-C", a.path, "rev-parse", "main"])
    for number in 1...2 {
        try Data("\(number)\n".utf8).write(to: a.appendingPathComponent("rewrite.txt"))
        _ = try git(["-C", a.path, "add", "rewrite.txt"]); _ = try git(["-C", a.path, "commit", "-qm", "old \(number)"])
    }
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: state)
    let oldTip = try git(["-C", b.path, "rev-parse", "refs/remotes/a/main"])
    _ = try git(["-C", a.path, "switch", "-qc", "new-base", initial])
    try Data("new base\n".utf8).write(to: a.appendingPathComponent("base.txt"))
    _ = try git(["-C", a.path, "add", "base.txt"]); _ = try git(["-C", a.path, "commit", "-qm", "new base"])
    _ = try git(["-C", a.path, "switch", "-q", "main"])
    _ = try git(["-C", a.path, "rebase", "--onto", "new-base", initial, "main"])
    let newTip = try git(["-C", a.path, "rev-parse", "main"]), localMain = try git(["-C", b.path, "rev-parse", "main"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: state)
    #expect(try git(["-C", b.path, "rev-parse", "refs/remotes/a/main"]) == newTip)
    #expect(try git(["-C", b.path, "rev-parse", "main"]) == localMain)
    #expect(try git(["-C", b.path, "cat-file", "-t", oldTip]) == "commit")
}

@Test("synchronization remains safe during destination garbage collection")
func concurrentGarbageCollection() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let a = fixture.a.appendingPathComponent("project"), b = fixture.b.appendingPathComponent("project")
    let localMain = try git(["-C", b.path, "rev-parse", "main"])
    for number in 1...12 {
        try Data(String(repeating: "\(number)-payload\n", count: 500).utf8)
            .write(to: a.appendingPathComponent("payload.txt"))
        _ = try git(["-C", a.path, "add", "payload.txt"])
        _ = try git(["-C", a.path, "commit", "-qm", "commit \(number)"])
    }
    let gc = Process()
    gc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    gc.arguments = ["git", "-C", b.path, "gc", "--aggressive"]
    gc.standardOutput = FileHandle.nullDevice; gc.standardError = FileHandle.nullDevice
    try gc.run()
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)
    gc.waitUntilExit()

    #expect(gc.terminationStatus == 0)
    #expect(try git(["-C", b.path, "rev-parse", "main"]) == localMain)
    #expect(try git(["-C", b.path, "fsck", "--no-dangling"]).isEmpty)
    #expect(try git(["-C", b.path, "rev-parse", "refs/remotes/a/main"]) == git(["-C", a.path, "rev-parse", "main"]))
}

@Test("an interrupted pack leaves refs and repository integrity unchanged")
func interruptedPack() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let source = try #require(Repository.discover(in: fixture.a).first)
    let destination = try #require(Repository.discover(in: fixture.b).first)
    let oid = try git(["-C", source.url.path, "rev-parse", "main"])
    let pack = try source.pack(oid: oid, excluding: [])
    let before = try git(["-C", destination.url.path, "show-ref"])
    #expect(throws: (any Error).self) {
        try destination.install(pack: pack.prefix(pack.count / 2), target: oid)
    }
    #expect(try git(["-C", destination.url.path, "show-ref"]) == before)
    #expect(try git(["-C", destination.url.path, "fsck", "--no-dangling"]).isEmpty)
}

@Test("pack batching ignores destination objects absent from the source")
func packBatchFiltersKnownObjects() throws {
    let fixture = try Fixture(); try fixture.cloneToB()
    let source = try #require(Repository.discover(in: fixture.a).first)
    let destination = try #require(Repository.discover(in: fixture.b).first)
    let known = try git(["-C", source.url.path, "rev-parse", "main"])
    try Data("two\n".utf8).write(to: source.url.appendingPathComponent("file.txt"))
    _ = try git(["-C", source.url.path, "commit", "-qam", "second"])
    let target = try git(["-C", source.url.path, "rev-parse", "main"])

    let pack = try source.pack(
        oid: target,
        excluding: [known, String(repeating: "0", count: known.count)]
    )
    try destination.install(pack: pack, target: target)

    #expect(try git(["-C", destination.url.path, "cat-file", "-t", target]) == "commit")
}

@Test("tags and stash use machine-specific namespaces")
func tagsAndStash() throws {
    let fixture = try Fixture()
    let source = fixture.a.appendingPathComponent("project")
    _ = try git(["-C", source.path, "tag", "v1"])
    try Data("stash\n".utf8).write(to: source.appendingPathComponent("file.txt"))
    _ = try git(["-C", source.path, "stash", "push", "-qm", "test stash"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)
    let destination = fixture.b.appendingPathComponent("project")
    #expect(try git(["-C", destination.path, "rev-parse", "refs/sync/A/tags/v1"]) == git(["-C", source.path, "rev-parse", "refs/tags/v1"]))
    #expect(try git(["-C", destination.path, "rev-parse", "refs/sync/A/stash"]) == git(["-C", source.path, "rev-parse", "refs/stash"]))
    #expect((try? git(["-C", destination.path, "rev-parse", "--verify", "refs/tags/v1"])) == nil)
    #expect((try? git(["-C", destination.path, "rev-parse", "--verify", "refs/stash"])) == nil)
}

@Test("framed session creates and synchronizes a peer project")
func framedSession() throws {
    let fixture = try Fixture()
    let aToB = Pipe(), bToA = Pipe()
    let a = try SyncSession(root: fixture.a, machine: "A",
                            input: bToA.fileHandleForReading, output: aToB.fileHandleForWriting,
                            stateURL: fixture.root.appendingPathComponent("session-A"))
    let b = try SyncSession(root: fixture.b, machine: "B",
                            input: aToB.fileHandleForReading, output: bToA.fileHandleForWriting,
                            stateURL: fixture.root.appendingPathComponent("session-B"))
    let sessions = DispatchGroup()
    for session in [a, b] {
        sessions.enter()
        DispatchQueue.global().async { defer { sessions.leave() }; try? session.run() }
    }

    let destination = fixture.b.appendingPathComponent("project")
    let expected = try git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"])
    let deadline = Date().addingTimeInterval(10)
    var received: String?
    while Date() < deadline, received == nil {
        received = try? git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"])
        if received == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(received == expected)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("file.txt").path))

    _ = try git(["-C", destination.path, "config", "user.name", "Test"])
    _ = try git(["-C", destination.path, "config", "user.email", "test@example.com"])
    _ = try git(["-C", destination.path, "switch", "-qc", "main", "refs/remotes/a/main"])
    try Data("from B\n".utf8).write(to: destination.appendingPathComponent("from-b.txt"))
    _ = try git(["-C", destination.path, "add", "from-b.txt"])
    _ = try git(["-C", destination.path, "commit", "-qm", "from B"])
    let expectedFromB = try git(["-C", destination.path, "rev-parse", "main"])
    let reverseDeadline = Date().addingTimeInterval(10)
    var reverse: String?
    while Date() < reverseDeadline, reverse != expectedFromB {
        reverse = try? git(["-C", fixture.a.appendingPathComponent("project").path,
                            "rev-parse", "refs/remotes/b/main"])
        if reverse != expectedFromB { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(reverse == expectedFromB)

    try? aToB.fileHandleForWriting.close(); try? bToA.fileHandleForWriting.close()
    try Data().write(to: fixture.a.appendingPathComponent("wake"))
    try Data().write(to: fixture.b.appendingPathComponent("wake"))
    #expect(sessions.wait(timeout: .now() + 5) == .success)
}

@Test("framed sessions synchronize only explicitly enabled projects")
func framedSessionSelection() throws {
    let fixture = try Fixture()
    let excluded = fixture.a.appendingPathComponent("excluded")
    try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
    _ = try git(["init", "-q", "-b", "main", excluded.path])

    let aToB = Pipe(), bToA = Pipe()
    let selected: Set<String> = ["project"]
    let a = try SyncSession(root: fixture.a, machine: "A",
                            input: bToA.fileHandleForReading, output: aToB.fileHandleForWriting,
                            stateURL: fixture.root.appendingPathComponent("selected-A"), repositories: selected)
    let b = try SyncSession(root: fixture.b, machine: "B",
                            input: aToB.fileHandleForReading, output: bToA.fileHandleForWriting,
                            stateURL: fixture.root.appendingPathComponent("selected-B"), repositories: selected)
    let sessions = DispatchGroup()
    for session in [a, b] {
        sessions.enter()
        DispatchQueue.global().async { defer { sessions.leave() }; try? session.run() }
    }

    let destination = fixture.b.appendingPathComponent("project")
    let expected = try git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"])
    let deadline = Date().addingTimeInterval(5)
    var received: String?
    while Date() < deadline, received == nil {
        received = try? git(["-C", destination.path, "rev-parse", "refs/remotes/a/main"])
        if received == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(received == expected)
    #expect(!FileManager.default.fileExists(atPath: fixture.b.appendingPathComponent("excluded").path))

    try? aToB.fileHandleForWriting.close(); try? bToA.fileHandleForWriting.close()
    try Data().write(to: fixture.a.appendingPathComponent("wake"))
    try Data().write(to: fixture.b.appendingPathComponent("wake"))
    #expect(sessions.wait(timeout: .now() + 5) == .success)
}

@Test("receive-only backup never publishes its refs to the source")
func framedSessionReceiveOnly() throws {
    let fixture = try Fixture()
    let backupRepository = fixture.b.appendingPathComponent("project.git")
    _ = try git(["clone", "-q", "--bare", fixture.a.appendingPathComponent("project").path,
                 backupRepository.path])
    _ = try git(["-C", backupRepository.path, "update-ref", "refs/heads/backup-only",
                 git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"])])

    let aToB = Pipe(), bToA = Pipe()
    let source = try SyncSession(root: fixture.a, machine: "A",
                                 input: bToA.fileHandleForReading, output: aToB.fileHandleForWriting,
                                 stateURL: fixture.root.appendingPathComponent("backup-source"))
    let catalogLock = NSLock()
    var receivedCatalog: [String]?
    let backup = try SyncSession(root: fixture.b, machine: "B",
                                 input: aToB.fileHandleForReading, output: bToA.fileHandleForWriting,
                                 stateURL: fixture.root.appendingPathComponent("backup-destination"),
                                 receiveOnly: true,
                                 catalogObserver: { machine, repositories in
                                     #expect(machine == "A")
                                     catalogLock.lock(); receivedCatalog = repositories; catalogLock.unlock()
                                 })
    let sessions = DispatchGroup()
    for session in [source, backup] {
        sessions.enter()
        DispatchQueue.global().async { defer { sessions.leave() }; try? session.run() }
    }

    let expected = try git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"])
    let deadline = Date().addingTimeInterval(5)
    var received: String?
    while Date() < deadline, received != expected {
        received = try? git(["-C", backupRepository.path, "rev-parse", "refs/remotes/a/main"])
        if received != expected { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(received == expected)
    catalogLock.lock(); let catalog = receivedCatalog; catalogLock.unlock()
    #expect(catalog == ["project"])
    #expect((try? git(["-C", fixture.a.appendingPathComponent("project").path,
                      "rev-parse", "--verify", "refs/remotes/b/main"])) == nil)

    try? aToB.fileHandleForWriting.close(); try? bToA.fileHandleForWriting.close()
    try Data().write(to: fixture.a.appendingPathComponent("wake"))
    #expect(sessions.wait(timeout: .now() + 5) == .success)
}

@Test("framed sessions synchronize large projects in both directions")
func framedSessionLargeBidirectionalPacks() throws {
    let fixture = try Fixture()
    let other = fixture.b.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    _ = try git(["init", "-q", "-b", "main", other.path])
    for repository in [fixture.a.appendingPathComponent("project"), other] {
        _ = try git(["-C", repository.path, "config", "user.name", "Test"])
        _ = try git(["-C", repository.path, "config", "user.email", "test@example.com"])
        try Data((0..<512 * 1024).map { _ in UInt8.random(in: .min ... .max) })
            .write(to: repository.appendingPathComponent("payload.bin"))
        _ = try git(["-C", repository.path, "add", "payload.bin"])
        _ = try git(["-C", repository.path, "commit", "-qm", "large payload"])
    }

    let aToB = Pipe(), bToA = Pipe()
    let a = try SyncSession(root: fixture.a, machine: "A",
                            input: bToA.fileHandleForReading, output: aToB.fileHandleForWriting,
                            stateURL: fixture.root.appendingPathComponent("session-A"))
    let b = try SyncSession(root: fixture.b, machine: "B",
                            input: aToB.fileHandleForReading, output: bToA.fileHandleForWriting,
                            stateURL: fixture.root.appendingPathComponent("session-B"))
    let sessions = DispatchGroup()
    for session in [a, b] {
        sessions.enter()
        DispatchQueue.global().async { defer { sessions.leave() }; try? session.run() }
    }

    let expectedA = try git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"])
    let expectedB = try git(["-C", other.path, "rev-parse", "main"])
    let deadline = Date().addingTimeInterval(5)
    var receivedA: String?, receivedB: String?
    while Date() < deadline, receivedA != expectedA || receivedB != expectedB {
        receivedA = try? git(["-C", fixture.b.appendingPathComponent("project").path,
                              "rev-parse", "refs/remotes/a/main"])
        receivedB = try? git(["-C", fixture.a.appendingPathComponent("other").path,
                              "rev-parse", "refs/remotes/b/main"])
        if receivedA != expectedA || receivedB != expectedB { Thread.sleep(forTimeInterval: 0.05) }
    }

    #expect(receivedA == expectedA)
    #expect(receivedB == expectedB)
    guard receivedA == expectedA, receivedB == expectedB else { return }
    try? aToB.fileHandleForWriting.close(); try? bToA.fileHandleForWriting.close()
    try Data().write(to: fixture.a.appendingPathComponent("wake"))
    try Data().write(to: fixture.b.appendingPathComponent("wake"))
    #expect(sessions.wait(timeout: .now() + 5) == .success)
}

@Test("initial snapshot does not repack shared history for every ref")
func initialSnapshotReusesSentObjects() throws {
    let fixture = try Fixture()
    let repository = fixture.a.appendingPathComponent("project")
    try Data((0..<1024 * 1024).map { _ in UInt8.random(in: .min ... .max) })
        .write(to: repository.appendingPathComponent("payload.bin"))
    _ = try git(["-C", repository.path, "add", "payload.bin"])
    _ = try git(["-C", repository.path, "commit", "-qm", "large shared history"])
    for number in 1...12 { _ = try git(["-C", repository.path, "tag", "v\(number)"]) }

    let sourceToRelay = Pipe(), relayToBackup = Pipe(), backupToSource = Pipe()
    let byteLock = NSLock()
    var sentBytes = 0
    let relay = DispatchGroup()
    relay.enter()
    sourceToRelay.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            try? relayToBackup.fileHandleForWriting.close()
            relay.leave()
            return
        }
        byteLock.lock(); sentBytes += data.count; byteLock.unlock()
        try? relayToBackup.fileHandleForWriting.write(contentsOf: data)
    }

    let source = try SyncSession(root: fixture.a, machine: "A",
                                 input: backupToSource.fileHandleForReading,
                                 output: sourceToRelay.fileHandleForWriting,
                                 stateURL: fixture.root.appendingPathComponent("source-state"))
    let backup = try SyncSession(root: fixture.b, machine: "B",
                                 input: relayToBackup.fileHandleForReading,
                                 output: backupToSource.fileHandleForWriting,
                                 stateURL: fixture.root.appendingPathComponent("backup-state"),
                                 receiveOnly: true)
    let sessions = DispatchGroup()
    for session in [source, backup] {
        sessions.enter()
        Thread.detachNewThread { defer { sessions.leave() }; try? session.run() }
    }
    Thread.sleep(forTimeInterval: 0.1)
    try Data().write(to: fixture.a.appendingPathComponent("wake"))

    let destination = fixture.b.appendingPathComponent("project.git")
    let expected = try git(["-C", repository.path, "rev-parse", "refs/tags/v12"])
    let deadline = Date().addingTimeInterval(10)
    var received: String?
    while Date() < deadline, received != expected {
        received = try? git(["-C", destination.path, "rev-parse", "refs/sync/A/tags/v12"])
        if received != expected { Thread.sleep(forTimeInterval: 0.05) }
    }
    byteLock.lock(); let totalBytes = sentBytes; byteLock.unlock()
    #expect(received == expected)
    #expect(totalBytes < 3 * 1024 * 1024)

    try? sourceToRelay.fileHandleForWriting.close()
    try? backupToSource.fileHandleForWriting.close()
    #expect(sessions.wait(timeout: .now() + 5) == .success)
    #expect(relay.wait(timeout: .now() + 5) == .success)
}

}
