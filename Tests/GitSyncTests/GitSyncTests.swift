import Foundation
import Testing
@testable import GitSyncCore

@Test("peer executable defaults to the installed app bundle")
func defaultPeerExecutable() {
    let configuration = Configuration(root: "/", machine: "mac", peer: "peer", remoteRoot: "/tmp")
    #expect(configuration.remoteExecutable == "/Applications/Git Sync.app/Contents/Resources/git-sync")
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
    #expect(throws: (any Error).self) { try connection.send(.hello("test")) }
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

    #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/sync/A/main"]) == remoteMain)
    #expect(try git(["-C", destination.path, "rev-parse", "refs/heads/main"]) == localMain)
    #expect(try git(["-C", destination.path, "symbolic-ref", "HEAD"]) == localHead)
    #expect(try git(["-C", destination.path, "write-tree"]) == localIndex)
    #expect(try String(contentsOf: destination.appendingPathComponent("file.txt"), encoding: .utf8) == localFile)
    #expect(try git(["-C", destination.path, "status", "--porcelain"]).isEmpty)
    #expect(try git(["-C", destination.path, "cat-file", "-t", remoteMain]) == "commit")
}

@Test("missing projects are initialized without a checkout")
func createsMissingProject() throws {
    let fixture = try Fixture()
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: fixture.state)
    let destination = fixture.b.appendingPathComponent("project")
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("file.txt").path))
    #expect(try git(["-C", destination.path, "rev-parse", "refs/remotes/sync/A/main"]) == git(["-C", fixture.a.appendingPathComponent("project").path, "rev-parse", "main"]))
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
    #expect((try? git(["-C", destination.path, "rev-parse", "--verify", "refs/remotes/sync/A/feature"])) == nil)
    let expired = try git(["-C", destination.path, "for-each-ref", "--format=%(refname)", "refs/sync/A/expired"])
    #expect(!expired.split(separator: "\n").isEmpty)
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
    let store = try StateStore(url: fixture.state)
    try store.accept(generation: 2, peer: "A", repository: "project", ref: "refs/heads/main")
    #expect(try !store.accept(generation: 1, peer: "A", repository: "project", ref: "refs/heads/main"))
    #expect(store.acceptedGeneration(peer: "A", repository: "project", ref: "refs/heads/main") == 2)
    let reopened = try StateStore(url: fixture.state)
    #expect(reopened.acceptedGeneration(peer: "A", repository: "project", ref: "refs/heads/main") == 2)
}

@Test("preflight returns only sorted repository name matches")
func preflightOverlap() {
    #expect(Runner.overlap(local: ["z", "shared", "a", "shādoe"],
                          remote: ["shared", "other", "a", "shādoe"]) == ["a", "shared", "shādoe"])
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
    #expect(try git(["-C", a.path, "rev-parse", "refs/remotes/sync/B/main"]) == bMain)
    #expect(try git(["-C", b.path, "rev-parse", "refs/remotes/sync/A/main"]) == aMain)
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
    let oldTip = try git(["-C", b.path, "rev-parse", "refs/remotes/sync/A/main"])
    _ = try git(["-C", a.path, "switch", "-qc", "new-base", initial])
    try Data("new base\n".utf8).write(to: a.appendingPathComponent("base.txt"))
    _ = try git(["-C", a.path, "add", "base.txt"]); _ = try git(["-C", a.path, "commit", "-qm", "new base"])
    _ = try git(["-C", a.path, "switch", "-q", "main"])
    _ = try git(["-C", a.path, "rebase", "--onto", "new-base", initial, "main"])
    let newTip = try git(["-C", a.path, "rev-parse", "main"]), localMain = try git(["-C", b.path, "rev-parse", "main"])
    try OneShot.sync(sourceRoot: fixture.a, destinationRoot: fixture.b, machine: "A", stateURL: state)
    #expect(try git(["-C", b.path, "rev-parse", "refs/remotes/sync/A/main"]) == newTip)
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
    #expect(try git(["-C", b.path, "rev-parse", "refs/remotes/sync/A/main"]) == git(["-C", a.path, "rev-parse", "main"]))
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
        received = try? git(["-C", destination.path, "rev-parse", "refs/remotes/sync/A/main"])
        if received == nil { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(received == expected)
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
    #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("file.txt").path))

    _ = try git(["-C", destination.path, "config", "user.name", "Test"])
    _ = try git(["-C", destination.path, "config", "user.email", "test@example.com"])
    _ = try git(["-C", destination.path, "switch", "-qc", "main", "refs/remotes/sync/A/main"])
    try Data("from B\n".utf8).write(to: destination.appendingPathComponent("from-b.txt"))
    _ = try git(["-C", destination.path, "add", "from-b.txt"])
    _ = try git(["-C", destination.path, "commit", "-qm", "from B"])
    let expectedFromB = try git(["-C", destination.path, "rev-parse", "main"])
    let reverseDeadline = Date().addingTimeInterval(10)
    var reverse: String?
    while Date() < reverseDeadline, reverse != expectedFromB {
        reverse = try? git(["-C", fixture.a.appendingPathComponent("project").path,
                            "rev-parse", "refs/remotes/sync/B/main"])
        if reverse != expectedFromB { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(reverse == expectedFromB)

    try? aToB.fileHandleForWriting.close(); try? bToA.fileHandleForWriting.close()
    try Data().write(to: fixture.a.appendingPathComponent("wake"))
    try Data().write(to: fixture.b.appendingPathComponent("wake"))
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
                              "rev-parse", "refs/remotes/sync/A/main"])
        receivedB = try? git(["-C", fixture.a.appendingPathComponent("other").path,
                              "rev-parse", "refs/remotes/sync/B/main"])
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
