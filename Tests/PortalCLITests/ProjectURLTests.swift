import Foundation
import Testing
@testable import portal

@Test func opensRepositoryFromPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repo = root.appendingPathComponent("space & café")
    let nested = repo.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["init", "-q", repo.path]
    try git.run()
    git.waitUntilExit()
    #expect(git.terminationStatus == 0)
    let url = try projectURL(path: nested.path)
    #expect(url.scheme == "gitsync")
    #expect(url.host == "project")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "name", value: "space & café")])
    #expect(throws: (any Error).self) { try projectURL(path: root.path) }
}
