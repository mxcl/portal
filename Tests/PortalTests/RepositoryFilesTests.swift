import Foundation
import Testing
@testable import PortalCore

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
    let staged = try repo.workingDiff(staged: true)
    let unstaged = try repo.workingDiff(staged: false)
    #expect(staged.contains("+staged"))
    #expect(staged.contains("rename from old.txt"))
    #expect(!staged.contains("+unstaged"))
    #expect(unstaged.contains("-staged\n+unstaged"))
    #expect(unstaged.contains("+new"))
    #expect(!unstaged.contains("hidden"))
    let changes = try #require(repo.snapshot().workingChanges?.files)
    #expect(try repo.workingChanges()?.files == changes)
    #expect(changes.map(\.path) == ["a.txt", "new name\n.txt", "untracked\n.txt"])
    #expect(changes.first { $0.path == "a.txt" }?.additions == 2)
    #expect(changes.first { $0.path == "a.txt" }?.deletions == 2)
    #expect(changes.first { $0.path == "new name\n.txt" }?.additions == 0)
    #expect(changes.first { $0.path == "untracked\n.txt" }?.additions == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index)
}

@Test("Working diffs support unborn HEAD, binary files, symlinks, and real Git errors")
func initialWorkingDiff() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try Git.run(["init", "-q", root.path])
    try Data("first\n".utf8).write(to: root.appendingPathComponent("new.txt"))
    try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                              withDestinationPath: "new.txt")
    let repository = Repository(name: "project", url: root)
    let files = try #require(repository.snapshot().workingChanges?.files)
    #expect(files.first { $0.path == "new.txt" }?.additions == 1)
    #expect(files.first { $0.path == "binary" }?.additions == nil)
    #expect(files.first { $0.path == "link" }?.additions == 1)
    let unstaged = try repository.workingDiff(staged: false)
    #expect(unstaged.contains("+first"))
    #expect(unstaged.contains("Binary files"))
    #expect(unstaged.contains("120000"))
    #expect(try repository.workingDiff(staged: true).isEmpty)
    _ = try Git.run(["-C", root.path, "add", "."])
    #expect(try repository.workingDiff(staged: true).contains("+first"))
    #expect(try repository.workingDiff(staged: false).isEmpty)
    #expect(throws: (any Error).self) {
        try Git.run(["-C", root.path, "diff", "--no-index", "--", "/dev/null", "missing"], successStatuses: [0, 1])
    }
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
