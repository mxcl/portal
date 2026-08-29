import Foundation
import Testing
@testable import GitSyncCore

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

private struct Fixture {
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
    #expect(store.acceptedGeneration(peer: "A", repository: "project", ref: "refs/heads/main") == 2)
    let reopened = try StateStore(url: fixture.state)
    #expect(reopened.acceptedGeneration(peer: "A", repository: "project", ref: "refs/heads/main") == 2)
}
