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

    @Test("daemon namespace routing preserves canonical IDs and round trips escaped IDs")
    func daemonNamespaceRoutingRoundTrip() {
        let canonical = SessionDaemonIdentity(namespace: .canonical, rawSessionID: "canonical-id")
        #expect(canonical.externalSessionID == "canonical-id")

        let reservedCanonical = SessionDaemonIdentity(
            namespace: .canonical,
            rawSessionID: "vaultty-dev-session:v1:portal:collision"
        )
        let decodedCanonical = SessionDaemonIdentity(externalSessionID: reservedCanonical.externalSessionID)
        #expect(decodedCanonical.namespace == .canonical)
        #expect(decodedCanonical.rawSessionID == reservedCanonical.rawSessionID)

        let portal = SessionDaemonIdentity(namespace: .portalDevelopment, rawSessionID: "same-id")
        #expect(portal.externalSessionID != "same-id")
        let decodedPortal = SessionDaemonIdentity(externalSessionID: portal.externalSessionID)
        #expect(decodedPortal.namespace == .portalDevelopment)
        #expect(decodedPortal.rawSessionID == "same-id")
        #expect(!decodedPortal.isPersistable)
    }

    @Test("daemon inventories preserve every session across both development hosts")
    func combinedDaemonInventories() {
        let maliwan = SessionDaemonInventory.combine(
            canonical: metadata(count: 7, prefix: "vaultty"),
            portalDevelopment: metadata(count: 5, prefix: "portal")
        )
        let pangolin = SessionDaemonInventory.combine(
            canonical: metadata(count: 1, prefix: "vaultty"),
            portalDevelopment: metadata(count: 3, prefix: "portal")
        )

        #expect(maliwan.count == 12)
        #expect(pangolin.count == 4)
        #expect(maliwan.prefix(7).map(\.sessionID) == (0..<7).map { "vaultty-\($0)" })
        #expect(maliwan.suffix(5).allSatisfy {
            SessionDaemonIdentity(externalSessionID: $0.sessionID).namespace == .portalDevelopment
        })
    }

    private func metadata(count: Int, prefix: String) -> [SessionMetadata] {
        (0..<count).map { index in
            SessionMetadata(
                sessionID: "\(prefix)-\(index)",
                title: prefix,
                cwd: "/tmp",
                createdAt: .distantPast,
                commandCount: 1,
                runningCommand: nil,
                commandHistory: []
            )
        }
    }
}
