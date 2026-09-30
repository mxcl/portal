import Foundation
import Testing
@testable import GitSyncCore

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
