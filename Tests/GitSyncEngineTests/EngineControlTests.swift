import Foundation
import Testing
@testable import GitSyncCore
@testable import GitSyncEngine

@Test("placement failures remain visible after restarting local sync")
@MainActor
func placementFailureSurvivesRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    _ = try Git.run(["init", "-q", "-b", "main", project.path])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-q", "--allow-empty", "-m", "Initial commit"])
    try Data("untracked\n".utf8).write(to: project.appendingPathComponent("README 2.md"))
    let model = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                            configuration: AppConfiguration(root: root.path, machine: "test"),
                            support: root.appendingPathComponent("support"))

    // Mirroring uses the same clean-checkout guard and recovery path as Archive.
    model.setPlacement(.mirrored, project: "project", hostID: nil)
    let deadline = Date().addingTimeInterval(5)
    while model.placementInProgress != nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.placementInProgress == nil)
    #expect(model.snapshot().error == "The checkout must be on a branch and completely clean.")
    #expect(FileManager.default.fileExists(atPath: project.appendingPathComponent("README 2.md").path))
}

@Test("event log counts only adjacent repeated events")
func eventLogCountsAdjacentRepeats() {
    #expect(countedEvents(["Fetch", "Fetch", "Idle", "Fetch"]) == [
        CountedEvent(message: "Fetch", count: 2),
        CountedEvent(message: "Idle"),
        CountedEvent(message: "Fetch"),
    ])
}

@Test("engine control requests round trip")
func engineControlRequestRoundTrip() throws {
    let request = EngineRequest(command: .addHost(
        peer: "atlas", root: "/srv/projects", executable: "git-sync",
        allowNameCollisions: false
    ))
    let decoded = try JSONDecoder().decode(
        EngineRequest.self,
        from: JSONEncoder().encode(request)
    )
    #expect(decoded.version == EngineControlProtocol.version)
    guard case let .addHost(peer, root, executable, allowNameCollisions) = decoded.command else {
        Issue.record("decoded the wrong command")
        return
    }
    #expect(peer == "atlas")
    #expect(root == "/srv/projects")
    #expect(executable == "git-sync")
    #expect(!allowNameCollisions)
}
