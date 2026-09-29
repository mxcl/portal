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
    _ = try git(local, ["config", "fetch.prune", "true"])
    _ = try git(local, ["config", "remote.origin.tagOpt", "--no-tags"])
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
    try repo.fetchGitHub("other/project", peerMachines: [])
    #expect(try git(local, ["tag", "--list", "--sort=refname"]) == "local-only")
    try repo.fetchGitHub("test/project", peerMachines: ["other"])
    #expect(try git(local, ["rev-parse", "refs/remotes/origin/main"]) == git(source, ["rev-parse", "HEAD"]))
    #expect(try git(local, ["rev-parse", "HEAD"]) == head)
    #expect(try git(local, ["tag", "--list", "--sort=refname"]) == "local-only\nremote-only")
    #expect(try Data(contentsOf: local.appendingPathComponent(".git/index")) == index)
    #expect(try String(contentsOf: local.appendingPathComponent("file"), encoding: .utf8) == "working")
    #expect(try String(contentsOf: local.appendingPathComponent(".git/FETCH_HEAD"), encoding: .utf8) == "sentinel")
    _ = try git(source, ["tag", "-d", "remote-only"])
    _ = try git(source, ["branch", "-D", "topic"])
    _ = try git(source, ["reset", "--hard", "HEAD~"])
    try repo.fetchGitHub("test/project", peerMachines: [])
    #expect(try git(local, ["rev-parse", "refs/remotes/origin/main"]) == head)
    #expect(!Git.succeeds(["-C", local.path, "show-ref", "--verify", "refs/remotes/origin/topic"]))
    #expect(try git(local, ["tag", "--list", "--sort=refname"]) == "local-only\nremote-only")
    // Even a fast-forward tag update must not replace a local tag.
    _ = try git(source, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "third"])
    _ = try git(source, ["tag", "local-only"])
    _ = try git(source, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "tag", "-a", "release/v2", "-m", "release"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: []) }
    #expect(try git(local, ["rev-parse", "refs/tags/local-only"]) == head)
    #expect(try git(local, ["rev-parse", "refs/tags/release/v2"]) == git(source, ["rev-parse", "refs/tags/release/v2"]))
    _ = try git(source, ["tag", "-d", "local-only"])
    _ = try git(local, ["symbolic-ref", "refs/tags/escape", "refs/heads/main"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: []) }
    _ = try git(local, ["symbolic-ref", "--delete", "refs/tags/escape"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: ["origin"]) }
    _ = try git(local, ["symbolic-ref", "refs/remotes/origin/escape", "refs/heads/main"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: []) }
    _ = try git(local, ["symbolic-ref", "--delete", "refs/remotes/origin/escape"])
    _ = try git(local, ["config", "remote.origin.mirror", "true"])
    #expect(throws: (any Error).self) { try repo.fetchGitHub("test/project", peerMachines: []) }
    _ = try git(local, ["config", "--unset", "remote.origin.mirror"])
    _ = try git(local, ["remote", "rename", "origin", "upstream"])
    _ = try git(source, ["tag", "upstream-only"])
    try repo.fetchGitHub("test/project", peerMachines: [])
    #expect(!Git.succeeds(["-C", local.path, "show-ref", "--verify", "refs/tags/upstream-only"]))
}

@Test("Older peer inventory does not require GitHub metadata")
func githubInventoryCompatibility() throws {
    let project = try JSONDecoder().decode(PeerProject.self, from: Data(#"{"name":"old","placement":"checkedOut"}"#.utf8))
    #expect(project.githubRepositories == nil)
    #expect(project.workingChanges == nil)
    #expect(project.branchTips == nil)
}

@Test("Git failures retain their diagnostic in localized error messages")
func syncErrorLocalizedDiagnostic() {
    let error: any Error = SyncError.command(["fetch", "origin"], "Permission denied (publickey).")
    #expect(error.localizedDescription == "git fetch origin: Permission denied (publickey).")
}

@Test("GUI Git processes can find installed remote and credential helpers")
func gitHelperSearchPath() {
    let environment = Git.environment(["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0"])
    let paths = environment["PATH"]!.components(separatedBy: ":")
    #expect(Array(paths.prefix(2)) == ["/usr/bin", "/bin"])
    #expect(paths.contains("/usr/local/bin"))
    #expect(paths.contains("/opt/homebrew/bin"))
    #expect(paths.contains(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path))
    #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    #expect(Git.environment(["PATH": "/usr/local/bin:/usr/bin"])["PATH"]!.components(separatedBy: ":").filter { $0 == "/usr/local/bin" }.count == 1)
}

@Test("GitHub branch status compares known refs without fetching or changing local work")
func githubKnownBranchStatus() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", "-b", "main", root.path])
    func git(_ args: [String]) throws -> String { try Git.text(["-C", root.path] + args) }
    _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "base"])
    let base = try git(["rev-parse", "HEAD"])
    let tree = try git(["rev-parse", "HEAD^{tree}"])
    func commit(_ message: String) throws -> String {
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit-tree", tree, "-p", base, "-m", message])
    }
    let local = try commit("local"), remote = try commit("remote")
    _ = try git(["remote", "add", "origin", "https://github.com/test/project.git"])
    let repository = Repository(name: "project", url: root)
    #expect(try repository.snapshot().githubBranchStatus == nil)
    #expect(try repository.branchTips() == RepositoryBranchTips(local: ["main": base], github: [:]))
    _ = try git(["update-ref", "refs/remotes/origin/main", base])
    #expect(try repository.snapshot().githubBranchStatus?.title == "Up to date")
    _ = try git(["update-ref", "refs/heads/main", local])
    #expect(try repository.snapshot().githubBranchStatus?.title == "1 ahead")
    _ = try git(["update-ref", "refs/remotes/origin/main", remote])
    #expect(try repository.snapshot().githubBranchStatus?.title == "1 ahead, 1 behind")
    #expect(try repository.branchTips() == RepositoryBranchTips(local: ["main": local], github: ["main": remote]))
    _ = try git(["branch", "topic", base])
    _ = try git(["update-ref", "refs/remotes/origin/topic", local])
    #expect(try repository.branchTips()?.github["topic"] == local)
    _ = try git(["update-ref", "refs/heads/main", base])
    #expect(try repository.snapshot().githubBranchStatus?.title == "1 behind")
    // An upstream may use a different branch name; same-name origin is not authoritative then.
    _ = try git(["config", "branch.main.remote", "origin"])
    _ = try git(["config", "branch.main.merge", "refs/heads/release"])
    #expect(try repository.snapshot().githubBranchStatus == nil)
    _ = try git(["update-ref", "refs/remotes/origin/release", base])
    #expect(try repository.snapshot().githubBranchStatus?.remoteBranch == "origin/release")
    #expect(try repository.branchTips()?.github["main"] == base)
    #expect(try repository.snapshot().githubBranchStatus?.title == "Up to date")
    _ = try git(["config", "branch.main.remote", "."])
    #expect(try repository.branchTips()?.github["main"] == nil)
    #expect(try repository.snapshot().githubBranchStatus == nil)
    _ = try git(["checkout", "--detach", "--quiet", base])
    #expect(try repository.snapshot().githubBranchStatus == nil)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/FETCH_HEAD").path))
    _ = try git(["config", "git-sync.mirrored", "true"])
    #expect(try repository.branchTips() == nil)
}

@Test("Optional hardware and branch status preserve older inventory and content decoding")
func optionalHostMetadataCompatibility() throws {
    let inspection = try JSONDecoder().decode(PeerInspection.self, from: Data(#"{"version":5,"machine":"old","repositories":[]}"#.utf8))
    #expect(inspection.hardware == nil)
    let snapshot = try JSONDecoder().decode(RepositorySnapshot.self, from: Data(#"{"commits":[],"references":[],"branches":[]}"#.utf8))
    #expect(snapshot.githubBranchStatus == nil)
    #expect(snapshot.branchTips == nil)
    let host = SyncHost(machine: "server", peer: "server", root: "/tmp", hardware: HostHardware(operatingSystem: "Linux"))
    #expect(try JSONDecoder().decode(SyncHost.self, from: JSONEncoder().encode(host)) == host)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(host)) as? [String: Any])
    legacy.removeValue(forKey: "hardware")
    #expect(try JSONDecoder().decode(SyncHost.self, from: JSONSerialization.data(withJSONObject: legacy)).hardware == nil)
    let current = PeerInspection(version: SyncProtocol.version, machine: "new", repositories: [], hardware: .current)
    #expect(try JSONDecoder().decode(PeerInspection.self, from: JSONEncoder().encode(current)) == current)
}
