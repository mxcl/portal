import Foundation
import Testing
@testable import VaulttyCore

@Suite("Remote terminal session client")
struct RemoteTerminalSessionClientTests {
    @Test("attaches as a Mac and preserves history")
    func attachesAndReceivesHistory() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )

        try await client.connect(peerID: "peer")
        try await transport.enqueue(RemoteMessage(
            kind: .terminalEvent,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            sequence: 1,
            payload: Data("history".utf8),
            isHistory: true
        ))

        #expect(try await client.receive() == .history("history"))
        let attach = try #require(await transport.sentMessages.first)
        #expect(attach.kind == .attach)
        #expect(attach.clientRole == .mac)
    }

    @Test("rejects gaps and ignores duplicate terminal events")
    func validatesSequence() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )
        try await client.connect(peerID: "peer")
        for sequence in [1, 1, 3] {
            try await transport.enqueue(RemoteMessage(
                kind: .terminalEvent,
                requestID: "request",
                macID: "mac",
                sessionID: "session",
                sequence: UInt64(sequence),
                payload: Data("output".utf8)
            ))
        }

        #expect(try await client.receive() == .output("output"))
        await #expect(throws: RemoteTerminalSessionError.sequenceGap(expected: 2)) {
            try await client.receive()
        }
    }
}

private actor FakeTerminalTransport: RemoteRelayTransport {
    private var responses: [Data] = []
    private(set) var sentMessages: [RemoteMessage] = []

    func connect(peerID: String) async throws {}

    func send(_ plaintext: Data) async throws {
        sentMessages.append(try JSONDecoder().decode(RemoteMessage.self, from: plaintext))
    }

    func receive() async throws -> Data {
        while responses.isEmpty {
            try Task.checkCancellation()
            await Task.yield()
        }
        return responses.removeFirst()
    }

    func disconnect() async {}

    func enqueue(_ message: RemoteMessage) throws {
        responses.append(try JSONEncoder().encode(message))
    }
}
