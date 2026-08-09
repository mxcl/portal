import Foundation
import Testing
@testable import PortalCore

@Suite("Remote session creation client")
struct RemoteSessionCreationClientTests {
    @Test("filters unrelated messages and returns the matching session")
    func matchingResponse() async throws {
        let transport = FakeCreationTransport { request in
            let session = RemoteCatalogSession(
                sessionID: try #require(request.sessionID),
                title: "~",
                cwd: "/Users/test",
                createdAt: Date(timeIntervalSince1970: 1),
                commandCount: 0,
                runningCommand: nil,
                attachedClientCount: 0
            )
            return [
                RemoteMessage(kind: .presence, requestID: "other", macID: request.macID),
                RemoteMessage(
                    kind: .sessionCreated,
                    requestID: request.requestID,
                    macID: request.macID,
                    sessionID: session.sessionID,
                    payload: try JSONEncoder().encode(session)
                ),
            ]
        }
        let client = RemoteSessionCreationClient { transport }

        let session = try await client.createSession(
            on: "mac",
            sessionID: "session",
            peerID: "phone"
        )

        #expect(session.sessionID == "session")
        #expect(await transport.didDisconnect)
        let request = try #require(await transport.sentMessages.first)
        #expect(request.kind == .createSession)
        #expect(request.macID == "mac")
        #expect(request.sessionID == "session")
    }

    @Test("surfaces a matching remote error")
    func remoteError() async {
        let transport = FakeCreationTransport { request in
            [RemoteMessage(
                kind: .error,
                requestID: request.requestID,
                macID: request.macID,
                sessionID: request.sessionID,
                payload: Data("No shell".utf8)
            )]
        }
        let client = RemoteSessionCreationClient { transport }

        await #expect(throws: RemoteSessionCreationError.remote("No shell")) {
            try await client.createSession(on: "mac", sessionID: "session", peerID: "phone")
        }
    }

    @Test("times out when the Mac does not respond")
    func timeout() async {
        let transport = FakeCreationTransport { _ in [] }
        let client = RemoteSessionCreationClient(timeoutNanoseconds: 10_000_000) { transport }

        await #expect(throws: RemoteSessionCreationError.timedOut) {
            try await client.createSession(on: "mac", sessionID: "session", peerID: "phone")
        }
        #expect(await transport.didDisconnect)
    }
}

private actor FakeCreationTransport: RemoteRelayTransport {
    typealias ResponseBuilder = @Sendable (RemoteMessage) throws -> [RemoteMessage]

    private let responseBuilder: ResponseBuilder
    private var responses: [Data] = []
    private(set) var sentMessages: [RemoteMessage] = []
    private(set) var didDisconnect = false

    init(responseBuilder: @escaping ResponseBuilder) {
        self.responseBuilder = responseBuilder
    }

    func connect(peerID: String) async throws {}

    func send(_ plaintext: Data) async throws {
        let request = try JSONDecoder().decode(RemoteMessage.self, from: plaintext)
        sentMessages.append(request)
        responses = try responseBuilder(request).map { try JSONEncoder().encode($0) }
    }

    func receive() async throws -> Data {
        while responses.isEmpty {
            try Task.checkCancellation()
            await Task.yield()
        }
        return responses.removeFirst()
    }

    func disconnect() async {
        didDisconnect = true
    }
}
