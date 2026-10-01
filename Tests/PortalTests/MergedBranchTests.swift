import Foundation
import Testing
@testable import PortalCore

private struct MergeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("merged-\(UUID())")
    var source: URL { root.appendingPathComponent("source") }
    var destination: URL { root.appendingPathComponent("backup") }
    var local: URL { source.appendingPathComponent("project") }
    var bare: URL { destination.appendingPathComponent("project.git") }
    var repository: Repository { Repository(name: "project", url: local) }

    init() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try Git.run(["init", "-b", "main", local.path])
        _ = try git(["config", "user.name", "Test"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["remote", "add", "origin", "https://github.com/owner/repo.git"])
        _ = try git(["commit", "--allow-empty", "-m", "base"])
        _ = try git(["checkout", "-b", "topic"])
        try Data("recover me".utf8).write(to: local.appendingPathComponent("work"))
        _ = try git(["add", "work"])
        _ = try git(["commit", "-m", "topic"])
        _ = try git(["config", "branch.topic.remote", "origin"])
        _ = try git(["config", "branch.topic.merge", "refs/heads/topic"])
        _ = try git(["checkout", "main"])
    }
    func git(_ args: [String], backup: Bool = false) throws -> String {
        try Git.text(["-C", (backup ? bare : local).path] + args)
    }
    func merge(branch: String = "topic", source: String = "owner/repo", oid: String? = nil) throws -> MergedBranch {
        MergedBranch(id: UUID(), repository: "owner/repo", sourceRepository: source, branch: branch,
                     oid: try oid ?? git(["rev-parse", "topic"]), baseBranch: "main", defaultBranch: "main",
                     pullRequest: 7, mergedAt: "2026-09-27T12:00:00Z")
    }
    func sync() throws {
        try OneShot.sync(sourceRoot: source, destinationRoot: destination, machine: "Mac",
                         stateURL: root.appendingPathComponent("source.json"), bareDestination: true)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
}

@Test("Merged branch cleanup preserves original history for every merge strategy", arguments: ["merge", "squash", "rebase"])
func mergedBranchRecovery(strategy: String) throws {
    let f = try MergeFixture()
    defer { f.close() }
    let merge = try f.merge()
    switch strategy {
    case "merge": _ = try f.git(["merge", "--no-ff", "topic", "-m", "merge"])
    case "squash":
        _ = try f.git(["merge", "--squash", "topic"])
        _ = try f.git(["commit", "-m", "squashed"])
    default:
        _ = try f.git(["commit", "--allow-empty", "-m", "advance main"])
        _ = try f.git(["cherry-pick", "topic"])
    }
    if strategy != "merge" {
        #expect(!Git.succeeds(["-C", f.local.path, "merge-base", "--is-ancestor", merge.oid, "main"]))
    }
    #expect(try f.repository.mergedBranchEligibility(merge) == .eligible)
    let backup = try f.repository.mergedBranchBackup(merge, machine: "Mac")
    #expect(backup.branchConfiguration.contains("branch.topic.remote\norigin\0"))
    // No backup objects: no receipt and the source ref stays intact.
    #expect(throws: (any Error).self) { try BackupIndex.retainMergedBranch(backup, in: f.destination) }
    #expect(try f.git(["rev-parse", "topic"]) == merge.oid)
    try f.sync()
    let receipt = try BackupIndex.retainMergedBranch(backup, in: f.destination)
    // Crash after retention, before deletion: the identical request is safe to replay.
    #expect(try BackupIndex.retainMergedBranch(backup, in: f.destination) == receipt)
    let head = try f.git(["rev-parse", "HEAD"])
    #expect(try f.repository.deleteMergedBranch(backup, receipt: receipt) == .eligible)
    #expect(try f.git(["rev-parse", "HEAD"]) == head)
    #expect(try f.repository.deleteMergedBranch(backup, receipt: receipt) == .skipped)
    try f.sync()
    try PeerRefWriter(repository: Repository(name: "project", url: f.bare), peer: "Mac")
        .pruneExpired(olderThan: .distantFuture)
    _ = try f.git(["reflog", "expire", "--expire=now", "--all"], backup: true)
    _ = try f.git(["gc", "--prune=now"], backup: true)
    #expect(try f.git(["rev-parse", backup.ref + "^{commit}"], backup: true) == merge.oid)
    let tag = try f.git(["cat-file", "tag", backup.ref], backup: true)
    let json = try #require(tag.range(of: "\n\n")).upperBound
    #expect(try JSONDecoder().decode(MergedBranchBackup.self, from: Data(tag[json...].utf8)) == backup)
    _ = try f.git(["update-ref", "refs/heads/recovered", merge.oid], backup: true)
    #expect(try f.git(["show", "recovered:work"], backup: true) == "recover me")
}

@Test("Cleanup refuses divergent, protected, symbolic, checked out, and raced branches")
func mergedBranchGuards() throws {
    let f = try MergeFixture()
    defer { f.close() }
    let merge = try f.merge()
    #expect(try f.repository.mergedBranchEligibility(f.merge(source: "fork/repo")) == .skipped)
    _ = try f.git(["remote", "add", "fork", "https://github.com/fork/repo.git"])
    #expect(try f.repository.mergedBranchEligibility(f.merge(source: "fork/repo")) == .skipped)
    #expect(try f.repository.mergedBranchEligibility(f.merge(branch: "main")) == .skipped)
    #expect(try f.repository.mergedBranchEligibility(f.merge(branch: "absent")) == .skipped)
    _ = try f.git(["symbolic-ref", "refs/heads/alias", "refs/heads/topic"])
    #expect(try f.repository.mergedBranchEligibility(f.merge(branch: "alias")) == .skipped)
    _ = try f.git(["symbolic-ref", "--delete", "refs/heads/alias"])
    let linked = f.root.appendingPathComponent("linked")
    _ = try f.git(["worktree", "add", linked.path, "topic"])
    #expect(try f.repository.mergedBranchEligibility(merge) == .deferred)
    _ = try f.git(["worktree", "remove", linked.path])
    // A detached HEAD during rebase still reserves the original branch.
    let rebase = f.local.appendingPathComponent(".git/rebase-merge")
    try FileManager.default.createDirectory(at: rebase, withIntermediateDirectories: true)
    try Data("refs/heads/topic\n".utf8).write(to: rebase.appendingPathComponent("head-name"))
    #expect(try f.repository.mergedBranchEligibility(merge) == .deferred)
    try FileManager.default.removeItem(at: rebase)
    _ = try f.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/topic"])
    _ = try f.git(["update-ref", "refs/remotes/origin/topic", merge.oid])
    #expect(try f.repository.mergedBranchEligibility(merge) == .skipped)
    _ = try f.git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
    try f.sync()
    let backup = try f.repository.mergedBranchBackup(merge, machine: "Mac")
    let receipt = try BackupIndex.retainMergedBranch(backup, in: f.destination)
    let other = try f.repository.mergedBranchBackup(f.merge(), machine: "Mac")
    #expect(throws: (any Error).self) { try f.repository.deleteMergedBranch(backup, receipt: other) }
    _ = try f.git(["checkout", "topic"])
    #expect(try f.repository.deleteMergedBranch(backup, receipt: receipt) == .deferred)
    _ = try f.git(["commit", "--allow-empty", "-m", "new work"])
    let newer = try f.git(["rev-parse", "HEAD"])
    _ = try f.git(["checkout", "main"])
    #expect(try f.repository.deleteMergedBranch(backup, receipt: receipt) == .skipped)
    #expect(try f.git(["rev-parse", "topic"]) == newer)
    // The same expected-old primitive rejects updates racing after the final eligibility read.
    #expect(throws: (any Error).self) {
        try f.git(["update-ref", "--no-deref", "-d", "refs/heads/topic", merge.oid])
    }
    #expect(try f.git(["rev-parse", "topic"]) == newer)
}

@Test("Retention fails on an incomplete object graph even when the tip exists")
func mergedBranchMissingObject() throws {
    let f = try MergeFixture()
    defer { f.close() }
    let backup = try f.repository.mergedBranchBackup(f.merge(), machine: "Mac")
    // Copy loose objects so one blob can be removed without corrupting a pack.
    _ = try Git.run(["clone", "--bare", "--no-hardlinks", f.local.path, f.bare.path])
    let blob = try f.git(["rev-parse", "topic:work"], backup: true)
    try FileManager.default.removeItem(at: f.bare.appendingPathComponent("objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
    #expect(throws: (any Error).self) { try BackupIndex.retainMergedBranch(backup, in: f.destination) }
    #expect(!Git.succeeds(["-C", f.bare.path, "show-ref", "--verify", backup.ref]))
    #expect(try f.git(["rev-parse", "topic"]) == backup.merge.oid)
}

@Test("Retention rejects alternate-backed and shallow history, and conflicting metadata")
func mergedBranchIncompleteHistory() throws {
    let f = try MergeFixture()
    defer { f.close() }
    try f.sync()
    let backup = try f.repository.mergedBranchBackup(f.merge(), machine: "Mac")
    let alternates = f.bare.appendingPathComponent("objects/info/alternates")
    try Data((f.local.appendingPathComponent(".git/objects").path + "\n").utf8).write(to: alternates)
    #expect(throws: (any Error).self) { try BackupIndex.retainMergedBranch(backup, in: f.destination) }
    try FileManager.default.removeItem(at: alternates)
    let shallow = f.bare.appendingPathComponent("shallow")
    try Data((backup.merge.oid + "\n").utf8).write(to: shallow)
    #expect(throws: (any Error).self) { try BackupIndex.retainMergedBranch(backup, in: f.destination) }
    try FileManager.default.removeItem(at: shallow)
    _ = try BackupIndex.retainMergedBranch(backup, in: f.destination)
    let changed = MergedBranchBackup(merge: backup.merge, machine: backup.machine,
                                    project: backup.project, branchConfiguration: "different")
    #expect(throws: (any Error).self) { try BackupIndex.retainMergedBranch(changed, in: f.destination) }
    #expect(try f.git(["rev-parse", "topic"]) == backup.merge.oid)
}

#if os(macOS)
@Test("Backup control confirms permanent retention and rejects incompatible versions")
func mergedBranchControl() throws {
    let f = try MergeFixture()
    defer { f.close() }
    try f.sync()
    let backup = try f.repository.mergedBranchBackup(f.merge(), machine: "Mac")
    let index = try BackupIndex(url: f.root.appendingPathComponent("index.json"))
    let socket = URL(fileURLWithPath: "/tmp/merged-\(UUID()).sock")
    let listener = try LocalBackupListener(url: socket)
    defer { listener.close() }
    func serve() {
        DispatchQueue.global().async {
            guard let connection = try? listener.accept() else { return }
            defer { try? connection.close() }
            guard (try? LocalBackupTransport.mode(from: connection)) == LocalBackupTransport.session else { return }
            try? BackupControlService.serve(connection, root: f.destination, index: index)
        }
    }
    serve()
    #expect(try Runner.retainMergedBranchLocally(backup, socket: socket) == backup)
    // Exercise the same framed stdin/stdout relay used behind SSH, including request EOF.
    serve()
    let input = Pipe(), output = Pipe()
    let completed = DispatchGroup()
    completed.enter()
    DispatchQueue.global().async {
        defer { try? output.fileHandleForWriting.close(); completed.leave() }
        do {
            try LocalBackupTransport.relay(to: socket, input: input.fileHandleForReading, output: output.fileHandleForWriting)
        } catch { Issue.record(error) }
    }
    try BackupControlConnection.send(BackupControlRequest(action: .retainMergedBranch, mergedBranch: backup), to: input.fileHandleForWriting)
    try input.fileHandleForWriting.close()
    #expect(try BackupControlConnection.receive(BackupControlResponse.self, from: output.fileHandleForReading).checked().mergedBranch == backup)
    #expect(completed.wait(timeout: .now() + 5) == .success)
    try input.fileHandleForReading.close()
    try output.fileHandleForReading.close()
    serve()
    let connection = try LocalBackupTransport.connect(mode: LocalBackupTransport.session, to: socket)
    defer { try? connection.close() }
    try BackupControlConnection.send(BackupControlRequest(version: 5, action: .retainMergedBranch, mergedBranch: backup), to: connection)
    #expect(throws: (any Error).self) {
        try BackupControlConnection.receive(BackupControlResponse.self, from: connection).checked()
    }
}
#endif
