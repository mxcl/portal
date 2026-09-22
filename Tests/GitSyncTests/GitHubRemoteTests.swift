import Foundation
import Testing
@testable import GitSyncCore

@Test("GitHub fetch ignores configured destinations and preserves all local work")
func githubFetchIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source"), local = root.appendingPathComponent("local")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    func git(_ at: URL, _ args: [String]) throws -> String { try Git.text(["-C", at.path] + args) }
    _ = try Git.run(["init", "-b", "main", source.path])
    _ = try git(source, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "first"])
    _ = try Git.run(["clone", source.path, local.path])
    _ = try git(local, ["remote", "set-url", "origin", "https://github.com/test/project.git"])
    _ = try git(local, ["config", "url.\(source.path).insteadOf", "https://github.com/test/project.git"])
    _ = try git(local, ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
    _ = try git(local, ["config", "fetch.pruneTags", "true"])
    _ = try git(local, ["tag", "local-only"])
    _ = try git(source, ["tag", "remote-only"])
    try Data("unsaved".utf8).write(to: local.appendingPathComponent("file"))
    _ = try git(local, ["add", "file"])
    try Data("working".utf8).write(to: local.appendingPathComponent("file"))
    let index = try Data(contentsOf: local.appendingPathComponent(".git/index"))
    let head = try git(local, ["rev-parse", "HEAD"])
    try Data("sentinel".utf8).write(to: local.appendingPathComponent(".git/FETCH_HEAD"))
    _ = try git(source, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "second"])
    _ = try git(source, ["branch", "topic"])
    let repo = Repository(name: "project", url: local)
    #expect(repo.githubRepositories == ["test/project"])
    try repo.fetchGitHub("test/project", peerMachines: ["other"])
    #expect(try git(local, ["rev-parse", "refs/remotes/origin/main"]) == git(source, ["rev-parse", "HEAD"]))
    #expect(try git(local, ["rev-parse", "HEAD"]) == head)
    #expect(try git(local, ["tag", "--list"]) == "local-only")
    #expect(try Data(contentsOf: local.appendingPathComponent(".git/index")) == index)
    #expect(try String(contentsOf: local.appendingPathComponent("file"), encoding: .utf8) == "working")
    #expect(try String(contentsOf: local.appendingPathComponent(".git/FETCH_HEAD"), encoding: .utf8) == "sentinel")
    _ = try git(source, ["branch", "-D", "topic"])
    _ = try git(source, ["reset", "--hard", "HEAD~"])
    try repo.fetchGitHub("test/project", peerMachines: [])
    #expect(try git(local, ["rev-parse", "refs/remotes/origin/main"]) == head)
    #expect(!Git.succeeds(["-C", local.path, "show-ref", "--verify", "refs/remotes/origin/topic"]))
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: ["origin"]) }
    _ = try git(local, ["symbolic-ref", "refs/remotes/origin/escape", "refs/heads/main"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: []) }
    _ = try git(local, ["symbolic-ref", "--delete", "refs/remotes/origin/escape"])
    _ = try git(local, ["config", "remote.origin.mirror", "true"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: []) }
}

@Test("Older peer inventory does not require GitHub metadata")
func githubInventoryCompatibility() throws {
    let project = try JSONDecoder().decode(PeerProject.self, from: Data(#"{"name":"old","placement":"checkedOut"}"#.utf8))
    #expect(project.githubRepositories == nil)
}

@Test("Git failures retain their diagnostic in localized error messages")
func syncErrorLocalizedDiagnostic() {
    let error: any Error = SyncError.command(["fetch", "origin"], "Permission denied (publickey).")
    #expect(error.localizedDescription == "git fetch origin: Permission denied (publickey).")
}
