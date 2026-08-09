import Foundation
import Testing
@testable import PortalCore

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

    @Test("terminal snapshots preserve the daemon grid and canonical screen")
    func terminalSnapshotRoundTrip() throws {
        let snapshot = RemoteTerminalSnapshot(
            rows: 24,
            cols: 80,
            contents: Data("\u{1B}[2J\u{1B}[Hvi".utf8)
        )
        let message = RemoteMessage(
            kind: .terminalSnapshot,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(snapshot)
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded.kind == .terminalSnapshot)
        #expect(try JSONDecoder().decode(
            RemoteTerminalSnapshot.self,
            from: #require(decoded.payload)
        ) == snapshot)
    }

    @Test("semantic terminal history round-trips as an additive relay message")
    func semanticTerminalHistoryRoundTrip() throws {
        let history = RemoteTerminalHistory(
            blocks: [
                .init(command: "git pull", cwd: "/repo", output: "Already up to date.\n", exitStatus: 0)
            ],
            currentCwd: "/repo",
            isAlternateScreenActive: true,
            isApplicationCursorModeActive: true
        )
        let message = RemoteMessage(
            kind: .terminalHistory,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(history)
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded.kind == .terminalHistory)
        #expect(try JSONDecoder().decode(
            RemoteTerminalHistory.self,
            from: #require(decoded.payload)
        ) == history)
    }

    @Test("semantic terminal history accepts the previous representation")
    func semanticTerminalHistoryPreviousRepresentation() throws {
        let current = RemoteTerminalHistory(
            blocks: [],
            currentCwd: "/repo",
            isAlternateScreenActive: true,
            isApplicationCursorModeActive: true
        )
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)
        ) as? [String: Any])
        object.removeValue(forKey: "isApplicationCursorModeActive")

        let previous = try JSONDecoder().decode(
            RemoteTerminalHistory.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(previous.isApplicationCursorModeActive == nil)
        var transcript = PortalBlockTranscript()
        transcript.restore(previous)
        #expect(!transcript.isApplicationCursorModeActive)
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

    @Test("completion operations are an exact allowlist")
    func completionOperationAllowlist() throws {
        for operation in RemoteCompletionOperation.allCases {
            let encoded = try JSONEncoder().encode(operation)
            #expect(try JSONDecoder().decode(
                RemoteCompletionOperation.self,
                from: encoded
            ) == operation)
        }

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                RemoteCompletionOperation.self,
                from: Data(#""arbitrary-command""#.utf8)
            )
        }
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
        #expect(decoded.clientCapabilities == nil)
        #expect(decoded.isHistory != true)
        #expect(!decoded.requestsSemanticTerminalHistory)
    }

    @Test("current phone attach remains decodable by the previous Mac")
    func currentPhonePreviousMacHistoryCompatibility() throws {
        let message = RemoteMessage(
            kind: .attach,
            requestID: "request",
            clientRole: .phone,
            clientCapabilities: [RemoteCapabilities.relayTerminalHistory]
        )

        let decoded = try JSONDecoder().decode(
            PreviousRemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded.kind == "attach")
        #expect(decoded.clientRole == "phone")
    }

    @Test("current Mac uses raw history for the previous phone")
    func previousPhoneCurrentMacHistoryFallback() throws {
        let fixture = Data(
            #"{"version":1,"kind":"attach","requestID":"request","clientRole":"phone"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: fixture)

        #expect(!decoded.requestsSemanticTerminalHistory)
    }

    @Test("session creation messages preserve their session identity")
    func sessionCreationRoundTrip() throws {
        let session = RemoteCatalogSession(
            sessionID: "new-session",
            title: "~",
            cwd: "/Users/test",
            createdAt: Date(timeIntervalSince1970: 42),
            commandCount: 0,
            lastCommandAt: Date(timeIntervalSince1970: 43),
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

    @Test("current peers decode previous state and catalog entries without command recency")
    func previousCommandRecencyFieldsDecode() throws {
        let previousState = Data(#"{"title":"build","cwd":"/repo","createdAt":42,"commandCount":1,"runningCommand":null,"commandHistory":[]}"#.utf8)
        let previousCatalogSession = Data(#"{"sessionID":"session-1","title":"build","cwd":"/repo","createdAt":42,"commandCount":1,"runningCommand":null,"attachedClientCount":0}"#.utf8)

        #expect(try JSONDecoder().decode(RemoteSessionState.self, from: previousState).lastCommandAt == nil)
        #expect(try JSONDecoder().decode(RemoteCatalogSession.self, from: previousCatalogSession).lastCommandAt == nil)
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

    @Test("catalog heartbeat retains inventory through failure and accepts recovery")
    func catalogInventoryRecovery() throws {
        let first = RemoteCatalogSession(
            sessionID: "first",
            title: "first",
            cwd: "/tmp",
            createdAt: .distantPast,
            commandCount: 1,
            runningCommand: nil,
            attachedClientCount: 0
        )
        let recovered = RemoteCatalogSession(
            sessionID: "recovered",
            title: "recovered",
            cwd: "/tmp",
            createdAt: .distantPast,
            commandCount: 1,
            runningCommand: nil,
            attachedClientCount: 0
        )
        var catalog = RemoteCatalog(generatedAt: .distantPast, macs: [])

        catalog.recordHeartbeat(
            RemoteMac(id: "mac", name: "Mac", online: true, lastSeen: Date(timeIntervalSince1970: 1), sessions: []),
            sessions: [first]
        )
        catalog.recordHeartbeat(
            RemoteMac(id: "mac", name: "Renamed", online: true, lastSeen: Date(timeIntervalSince1970: 2), sessions: []),
            sessions: nil
        )
        var mac = try #require(catalog.macs.first)
        #expect(mac.name == "Renamed")
        #expect(mac.lastSeen == Date(timeIntervalSince1970: 2))
        #expect(mac.sessions == [first])

        catalog.recordHeartbeat(
            RemoteMac(id: "mac", name: "Renamed", online: true, lastSeen: Date(timeIntervalSince1970: 3), sessions: []),
            sessions: [recovered]
        )
        mac = try #require(catalog.macs.first)
        #expect(mac.lastSeen == Date(timeIntervalSince1970: 3))
        #expect(mac.sessions == [recovered])

        catalog.recordHeartbeat(
            RemoteMac(id: "mac", name: "Renamed", online: true, lastSeen: Date(timeIntervalSince1970: 4), sessions: []),
            sessions: []
        )
        #expect(try #require(catalog.macs.first).sessions.isEmpty)
    }

    @Test("catalog heartbeat excludes sessions until they have a command")
    func catalogHeartbeatExcludesEmptySessions() throws {
        let empty = RemoteCatalogSession(
            sessionID: "empty",
            title: "~",
            cwd: "/Users/test",
            createdAt: .distantPast,
            commandCount: 0,
            runningCommand: nil,
            attachedClientCount: 0
        )
        var active = empty
        active.sessionID = "active"
        active.commandCount = 1
        var catalog = RemoteCatalog(generatedAt: .distantPast, macs: [])

        catalog.recordHeartbeat(
            RemoteMac(id: "mac", name: "Mac", online: true, sessions: []),
            sessions: [empty, active]
        )

        #expect(try #require(catalog.macs.first).sessions == [active])
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

private struct PreviousRemoteMessage: Decodable {
    let kind: String
    let clientRole: String?
}
