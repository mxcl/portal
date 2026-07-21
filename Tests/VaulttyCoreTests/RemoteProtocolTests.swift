import Foundation
import Testing
@testable import VaulttyCore

@Suite("Remote protocol")
struct RemoteProtocolTests {
    @Test("messages preserve opaque terminal payloads")
    func messageRoundTrip() throws {
        let message = RemoteMessage(
            kind: .terminalEvent,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            sequence: 42,
            payload: Data([0, 1, 2, 255])
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded == message)
    }

    @Test("semantic command submissions preserve their encrypted payload")
    func submitRoundTrip() throws {
        let message = RemoteMessage(
            kind: .submit,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: Data("git status".utf8)
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded == message)
    }

    @Test("session creation messages preserve their session identity")
    func sessionCreationRoundTrip() throws {
        let session = RemoteCatalogSession(
            sessionID: "new-session",
            title: "~",
            cwd: "/Users/test",
            createdAt: Date(timeIntervalSince1970: 42),
            commandCount: 0,
            runningCommand: nil,
            attachedClientCount: 0
        )
        let message = RemoteMessage(
            kind: .sessionCreated,
            requestID: "request",
            macID: "mac",
            sessionID: session.sessionID,
            payload: try JSONEncoder().encode(session)
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded == message)
        #expect(try JSONDecoder().decode(
            RemoteCatalogSession.self,
            from: #require(decoded.payload)
        ) == session)
    }

    @Test("legacy Macs decode without capabilities")
    func legacyMacCapabilities() throws {
        let data = Data("""
        {
            "id":"mac",
            "name":"Mac",
            "online":true,
            "lastSeen":0,
            "sessions":[]
        }
        """.utf8)

        let mac = try JSONDecoder().decode(RemoteMac.self, from: data)

        #expect(mac.capabilities == nil)
        #expect(!mac.supportsSessionCreation)
    }

    @Test("empty detached sessions are not remotely discoverable")
    func remoteSessionDiscoverability() {
        let empty = RemoteCatalogSession(
            sessionID: "empty",
            title: "~",
            cwd: "/Users/test",
            createdAt: Date(),
            commandCount: 0,
            runningCommand: nil,
            attachedClientCount: 0
        )
        let attached = RemoteCatalogSession(
            sessionID: "attached",
            title: "~",
            cwd: "/Users/test",
            createdAt: Date(),
            commandCount: 0,
            runningCommand: nil,
            attachedClientCount: 1
        )
        let used = RemoteCatalogSession(
            sessionID: "used",
            title: "project",
            cwd: "/Users/test/project",
            createdAt: Date(),
            commandCount: 1,
            runningCommand: nil,
            attachedClientCount: 0
        )

        #expect(!empty.isRemotelyDiscoverable)
        #expect(attached.isRemotelyDiscoverable)
        #expect(used.isRemotelyDiscoverable)
    }

    @Test("sequence tracker rejects replay and detects gaps")
    func sequenceValidation() {
        var tracker = RemoteSequenceTracker()

        #expect(tracker.accept(7) == .accepted)
        #expect(tracker.accept(7) == .duplicate)
        #expect(tracker.accept(9) == .gap(expected: 8))
        #expect(tracker.accept(8) == .accepted)
        #expect(tracker.lastSequence == 8)
    }
}
