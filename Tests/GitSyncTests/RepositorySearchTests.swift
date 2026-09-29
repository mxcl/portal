import Foundation
import Testing
@testable import GitSyncCore

@Test func paletteMatching() throws {
    #expect(PaletteMatch.rank("Main", query: "main") == 0)
    #expect(PaletteMatch.rank("main-feature", query: "main") == 1)
    #expect(PaletteMatch.rank("my-main", query: "main") == 2)
    #expect(PaletteMatch.rank("my-awesome-invention", query: "main") == 3)
    #expect(PaletteMatch.rank("main", query: "nope") == nil)
    #expect(PaletteMatch.isSHA("Ab12"))
    #expect(!PaletteMatch.isSHA("abc"))
    #expect(!PaletteMatch.isSHA("HEAD"))
    #expect(!PaletteMatch.isSHA("--all"))
    #expect(throws: (any Error).self) { try RepositorySearchReply(matches: [], version: 99).checked() }
}

@Test func repositoryPaletteSearch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String], input: String = "") throws -> String {
        String(decoding: try Git.run(["-C", root.path] + args, input: Data(input.utf8)), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try git(["init", "-q"])
    var stream = ""
    for i in 1...260 {
        let message = "Commit \(i)"
        stream += "commit refs/heads/main\nmark :\(i)\ncommitter Test <test@example.com> \(i) +0000\ndata \(message.utf8.count)\n\(message)\n"
        if i > 1 { stream += "from :\(i - 1)\n" }
        stream += "\n"
    }
    _ = try git(["fast-import", "--quiet"], input: stream)
    _ = try git(["symbolic-ref", "HEAD", "refs/heads/main"])
    let oldest = try git(["rev-list", "--max-parents=0", "main"])
    let tip = try git(["rev-parse", "main"])
    _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "tag", "-a", "release-old", "-m", "Release", oldest])
    let blob = try git(["hash-object", "-w", "--stdin"], input: "blob")
    _ = try git(["update-ref", "refs/tags/release-blob", blob])
    _ = try git(["update-ref", "refs/sync/peer/stash", tip])
    _ = try git(["update-ref", "refs/codex/snapshots/hidden", tip])
    let before = try git(["show-ref"])
    let repository = Repository(name: "project", url: root)
    #expect(try !repository.snapshot().commits.contains { $0.oid == oldest })
    let bySHA = try repository.search(String(oldest.prefix(7))).checked()
    #expect(bySHA.contains { $0.commit.oid == oldest && $0.reference == nil })
    let tags = try repository.search("release").checked()
    #expect(tags.count == 1)
    #expect(tags.first?.commit.oid == oldest)
    #expect(tags.first?.reference?.fullName == "refs/tags/release-old")
    #expect(try repository.search("stash").checked().isEmpty)
    #expect(try repository.search("hidden").checked().isEmpty)
    #expect(try repository.search("--all").checked().isEmpty)
    #expect(try git(["show-ref"]) == before)
    #expect(try git(["symbolic-ref", "HEAD"]) == "refs/heads/main")

    // Two different valid commit objects sharing a four-character prefix.
    for i in [326, 351] {
        let raw = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor Test <test@example.com> 1 +0000\ncommitter Test <test@example.com> 1 +0000\n\nCollision \(i)\n"
        _ = try git(["hash-object", "-t", "commit", "-w", "--stdin"], input: raw)
    }
    let collisions = try repository.search("42cb").checked().filter { $0.reference == nil }
    #expect(collisions.count >= 2)
    #expect(Set(collisions.map(\.commit.oid)).count == collisions.count)
}
