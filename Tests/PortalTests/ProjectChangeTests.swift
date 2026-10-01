import Foundation
import Testing
@testable import PortalCore

@Test("persistent project observation retains events during scans and then becomes idle")
func persistentProjectChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let watcher = try ProjectChangeWatcher(root: root)
    // Drain any startup events, then establish a quiet baseline.
    while try watcher.wait(milliseconds: 750) {}
    #expect(try !watcher.wait(milliseconds: 100))
    let nested = root.appendingPathComponent("new/nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    #expect(try watcher.wait(milliseconds: 3000))
    while try watcher.wait(milliseconds: 750) {}
    // Write before wait(), as would happen while a consumer is refreshing.
    try Data("first".utf8).write(to: nested.appendingPathComponent("file"))
    #expect(try watcher.wait(milliseconds: 3000))
    while try watcher.wait(milliseconds: 750) {}
    #expect(try !watcher.wait(milliseconds: 100))
    try Data("second".utf8).write(to: nested.appendingPathComponent("file"))
    #expect(try watcher.wait(milliseconds: 3000))
    #expect(throws: SyncError.self) { try ProjectChange(version: 0).checked() }
}

@Test("project pushes ignore build/index noise and identify only the changed project")
func meaningfulProjectChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = Repository(name: "first", url: root.appendingPathComponent("first"))
    let second = Repository(name: "second", url: root.appendingPathComponent("second"))
    for repository in [first, second] {
        try FileManager.default.createDirectory(at: repository.url, withIntermediateDirectories: true)
        _ = try Git.run(["init", "-q", "-b", "main", repository.url.path])
        try Data("build/\n".utf8).write(to: repository.url.appendingPathComponent(".gitignore"))
        try Data("first\n".utf8).write(to: repository.url.appendingPathComponent("file"))
        _ = try Git.run(["-C", repository.url.path, "add", "."])
        _ = try Git.run(["-C", repository.url.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                         "commit", "-qm", "initial"])
    }
    var scanner = ProjectChangeScanner()
    func scan() throws -> ProjectChange? { try scanner.scan([first, second]) }
    let initial = try #require(try scan())
    #expect(initial.projects["first"]?.snapshot.commits.isEmpty == true)
    #expect(try scan() == nil)
    let build = first.url.appendingPathComponent("build")
    try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
    try Data("noise".utf8).write(to: build.appendingPathComponent("output"))
    _ = try Git.run(["-C", first.url.path, "update-index", "--refresh"])
    #expect(try scan() == nil)
    try Data("other\n".utf8).write(to: first.url.appendingPathComponent("file"))
    let edit = try #require(try scan())
    #expect(edit.projects["first"]?.revision != initial.projects["first"]?.revision)
    #expect(edit.projects["second"] == initial.projects["second"])
    try Data("third\n".utf8).write(to: first.url.appendingPathComponent("file"))
    let sameCounts = try #require(try scan())
    #expect(sameCounts.projects["first"]?.snapshot.workingChanges == edit.projects["first"]?.snapshot.workingChanges)
    #expect(sameCounts.projects["first"]?.revision != edit.projects["first"]?.revision)
    _ = try Git.run(["-C", first.url.path, "add", "file"])
    let staged = try #require(try scan())
    #expect(staged.projects["first"]?.snapshot.workingChanges?.staged == 1)
    _ = try Git.run(["-C", second.url.path, "tag", "new-tag"])
    let tagged = try #require(try scan())
    #expect(tagged.projects["first"] == staged.projects["first"])
    #expect(tagged.projects["second"]?.revision != staged.projects["second"]?.revision)
    #expect(try scanner.scan([first])?.projects["second"] == nil)
}
