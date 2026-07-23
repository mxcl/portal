import Foundation
import Testing
@testable import VaulttyCore

@Suite("Session metadata wire format")
struct SessionTypesTests {
    @Test("decodes the session daemon's camel-case identifier")
    func decodesSessionDaemonIdentifier() throws {
        let data = Data(#"[{"sessionId":"session-1","title":"Vaultty","cwd":"/tmp","createdAt":1,"commandCount":2,"runningCommand":null,"commandHistory":[],"attachedClientCount":1}]"#.utf8)

        let sessions = try JSONDecoder().decode([SessionMetadata].self, from: data)

        #expect(sessions.map(\.sessionID) == ["session-1"])
    }

    @Test("relay session locations survive persistence")
    func relaySessionLocationRoundTrip() throws {
        let reference = SessionRef(
            location: .relayMac("remote-mac"),
            sessionID: "session-1",
            hostName: "Studio Mac"
        )

        let decoded = try JSONDecoder().decode(
            SessionRef.self,
            from: JSONEncoder().encode(reference)
        )

        #expect(decoded == reference)
        #expect(decoded.hostName == "Studio Mac")
        #expect(decoded == SessionRef(
            location: .relayMac("remote-mac"),
            sessionID: "session-1",
            hostName: "Renamed Mac"
        ))

        let previous = try JSONDecoder().decode(
            SessionRef.self,
            from: Data(#"{"location":{"kind":"relay","macID":"remote-mac"},"sessionID":"session-1"}"#.utf8)
        )
        #expect(previous.hostName == nil)
    }
}
