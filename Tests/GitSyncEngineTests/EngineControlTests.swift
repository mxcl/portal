import Foundation
import Testing
@testable import GitSyncEngine

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
