import Foundation
import Testing
@testable import GitSyncCore

@Test("Editor lists Git paths and distinguishes both sides of the index without modifying it")
func editorGitFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws { _ = try Git.run(["-C", root.path] + args) }
    func write(_ path: String, _ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    try git(["init"])
    try git(["config", "user.name", "Test"])
    try git(["config", "user.email", "test@example.com"])
    try write("a.txt", "original\n")
    try write("old.txt", "rename me\n")
    try write(".gitignore", "ignored\n")
    try git(["add", "."])
    try git(["commit", "-m", "initial"])
    try write("a.txt", "staged\n")
    try git(["add", "a.txt"])
    try write("a.txt", "unstaged\n")
    try git(["mv", "old.txt", "new name\n.txt"])
    try write("untracked\n.txt", "new\n")
    try write("ignored", "hidden\n")
    let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
    let repo = Repository(name: "test", url: root)
    let files = try repo.files()
    #expect(files.first { $0.path == "a.txt" }?.status == "MM")
    #expect(files.first { $0.path == "new name\n.txt" }?.isStaged == true)
    #expect(files.first { $0.path == "untracked\n.txt" }?.isUntracked == true)
    #expect(!files.contains { $0.path == "old.txt" || $0.path == "ignored" })
    #expect(try repo.fileDiff(path: "a.txt", staged: true).contains("+staged"))
    #expect(try repo.fileDiff(path: "a.txt", staged: false).contains("+unstaged"))
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
}

@Test("Editor saves lossless UTF-8 and refuses outside edits, binary files, symlinks, and traversal")
func editorSaveSafety() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("script")
    let original = Data("\u{feff}héllo\r\n".utf8)
    try original.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    let file = try RepositoryTextFile(repository: root, path: "script")
    let saved = try file.save(file.text + "new\r\n")
    #expect(try Data(contentsOf: url) == original + Data("new\r\n".utf8))
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    try Data("outside edit".utf8).write(to: url)
    #expect(throws: (any Error).self) { try saved.save("overwrite") }
    #expect(try String(contentsOf: url, encoding: .utf8) == "outside edit")
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: url)
    #expect(throws: (any Error).self) { try RepositoryTextFile(repository: root, path: "link") }
    #expect(throws: (any Error).self) { try RepositoryTextFile(repository: root, path: "../outside") }
    try Data([0, 1, 2]).write(to: url)
    #expect(throws: (any Error).self) { try RepositoryTextFile(repository: root, path: "script") }
}
