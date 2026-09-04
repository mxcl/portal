import Foundation
import Testing
@testable import GitSyncEngine

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
