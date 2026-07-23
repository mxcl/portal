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

    @Test("completion messages preserve typed operations and opaque payloads")
    func completionRoundTrip() throws {
        let request = RemoteCompletionRequest(
            operationID: "completion",
            operation: .completePath,
            payload: Data(#"{"cwd":"/tmp","prefix":"s"}"#.utf8)
        )
        let message = RemoteMessage(
            kind: .completionRequest,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(request)
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded == message)
        #expect(try JSONDecoder().decode(
            RemoteCompletionRequest.self,
            from: #require(decoded.payload)
        ) == request)
    }

    @Test("unknown message kinds remain decodable and round-trip")
    func unknownMessageKindsDecode() throws {
        let fixture = Data(#"{"version":1,"kind":"futureFeature","requestID":"request"}"#.utf8)

        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: fixture)

        #expect(decoded.kind == .unknown("futureFeature"))
        let roundTrip = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(decoded)
        )
        #expect(roundTrip == decoded)
    }

    @Test("previous relay messages decode with Mac-control defaults")
    func previousRelayMessagesDecode() throws {
        let fixture = Data(
            #"{"version":1,"kind":"terminalEvent","requestID":"request","sequence":1,"payload":"aGk="}"#.utf8
        )

        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: fixture)

        #expect(decoded.clientRole == nil)
        #expect(decoded.isHistory != true)
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

    @Test("a created session is immediately visible in its Mac catalog")
    func createdSessionUpdatesCatalog() throws {
        let existing = RemoteCatalogSession(
            sessionID: "existing",
            title: "src",
            cwd: "/Users/test/src",
            createdAt: Date(timeIntervalSince1970: 1),
            commandCount: 1,
            runningCommand: nil,
            attachedClientCount: 0
        )
        let created = RemoteCatalogSession(
            sessionID: "created",
            title: "~",
            cwd: "/Users/test",
            createdAt: Date(timeIntervalSince1970: 2),
            commandCount: 0,
            runningCommand: nil,
            attachedClientCount: 0
        )
        var catalog = RemoteCatalog(
            generatedAt: Date(timeIntervalSince1970: 3),
            macs: [
                RemoteMac(
                    id: "target",
                    name: "Maliwan",
                    online: true,
                    sessions: [existing]
                ),
                RemoteMac(
                    id: "other",
                    name: "Pangolin",
                    online: true,
                    sessions: []
                ),
            ]
        )

        catalog.record(created, onMac: "target")

        let target = try #require(catalog.macs.first { $0.id == "target" })
        #expect(target.sessions.map(\.sessionID) == ["existing", "created"])
        #expect(catalog.macs.first { $0.id == "other" }?.sessions.isEmpty == true)
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
