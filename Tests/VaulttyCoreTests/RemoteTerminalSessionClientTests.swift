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

    @Test("gates completion on capability and routes matching responses")
    func completionCapabilityAndResponse() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )
        try await client.connect(peerID: "peer")

        await #expect(throws: RemoteTerminalSessionError.completionUnavailable) {
            try await client.complete(
                operation: .completeCommands,
                payload: Data(),
                timeoutNanoseconds: 1_000_000_000
            )
        }

        try await transport.enqueue(RemoteMessage(
            kind: .capabilities,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(RemoteCapabilities(
                values: [RemoteCapabilities.relayCompletion]
            ))
        ))
        #expect(try await client.receive() == .capabilities([
            RemoteCapabilities.relayCompletion
        ]))

        let completion = Task {
            try await client.complete(
                operation: .completeCommands,
                payload: Data("request".utf8),
                timeoutNanoseconds: 1_000_000_000
            )
        }
        let sent = try await transport.waitForMessage(kind: .completionRequest)
        let request = try JSONDecoder().decode(
            RemoteCompletionRequest.self,
            from: #require(sent.payload)
        )
        try await transport.enqueue(RemoteMessage(
            kind: .completionResponse,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(RemoteCompletionResponse(
                operationID: request.operationID,
                payload: Data("response".utf8)
            ))
        ))
        try await transport.enqueue(RemoteMessage(
            kind: .presence,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: Data("1".utf8)
        ))

        #expect(try await client.receive() == .presence(1))
        #expect(try await completion.value == Data("response".utf8))
    }

    @Test("timed out completion sends cancellation")
    func completionTimeoutCancelsRemoteWork() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )
        try await client.connect(peerID: "peer")
        try await transport.enqueue(RemoteMessage(
            kind: .capabilities,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(RemoteCapabilities(
                values: [RemoteCapabilities.relayCompletion]
            ))
        ))
        _ = try await client.receive()

        await #expect(throws: RemoteTerminalSessionError.completionTimedOut) {
            try await client.complete(
                operation: .completePath,
                payload: Data(),
                timeoutNanoseconds: 1_000_000
            )
        }

        _ = try await transport.waitForMessage(kind: .completionCancel)
    }

    @Test("rejects oversized completion input before sending")
    func completionInputLimit() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )
        try await advertiseCompletion(to: client, through: transport)

        await #expect(throws: RemoteTerminalSessionError.invalidResponse) {
            try await client.complete(
                operation: .runGenerator,
                payload: Data(
                    repeating: 0,
                    count: RemoteCompletionRequest.maximumPayloadSize + 1
                ),
                timeoutNanoseconds: 1_000_000_000
            )
        }
        #expect(await transport.sentMessages.allSatisfy {
            $0.kind != .completionRequest
        })
    }

    @Test("cancellation discards late responses without disturbing terminal traffic")
    func completionCancellationAndLateResponse() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )
        try await advertiseCompletion(to: client, through: transport)

        let completion = Task {
            try await client.complete(
                operation: .runGenerator,
                payload: Data(),
                timeoutNanoseconds: 1_000_000_000
            )
        }
        let sent = try await transport.waitForMessage(kind: .completionRequest)
        let request = try JSONDecoder().decode(
            RemoteCompletionRequest.self,
            from: #require(sent.payload)
        )
        completion.cancel()
        _ = try await transport.waitForMessage(kind: .completionCancel)
        await #expect(throws: CancellationError.self) {
            try await completion.value
        }

        try await transport.enqueue(RemoteMessage(
            kind: .completionResponse,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(RemoteCompletionResponse(
                operationID: request.operationID,
                payload: Data("late".utf8)
            ))
        ))
        try await transport.enqueue(RemoteMessage(
            kind: .terminalEvent,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            sequence: 1,
            payload: Data("still connected".utf8)
        ))

        #expect(try await client.receive() == .output("still connected"))
    }

    @Test("reconnect invalidates advertised completion capability")
    func reconnectInvalidatesCapability() async throws {
        let transport = FakeTerminalTransport()
        let client = RemoteTerminalSessionClient(
            macID: "mac",
            sessionID: "session",
            requestID: "request",
            transport: transport
        )
        try await advertiseCompletion(to: client, through: transport)

        try await client.reconnect(peerID: "peer")

        await #expect(throws: RemoteTerminalSessionError.completionUnavailable) {
            try await client.complete(
                operation: .completeCommands,
                payload: Data(),
                timeoutNanoseconds: 1_000_000_000
            )
        }
    }

    private func advertiseCompletion(
        to client: RemoteTerminalSessionClient,
        through transport: FakeTerminalTransport
    ) async throws {
        try await client.connect(peerID: "peer")
        try await transport.enqueue(RemoteMessage(
            kind: .capabilities,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(RemoteCapabilities(
                values: [RemoteCapabilities.relayCompletion]
            ))
        ))
        _ = try await client.receive()
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

    func waitForMessage(kind: RemoteMessageKind) async throws -> RemoteMessage {
        while true {
            if let message = sentMessages.first(where: { $0.kind == kind }) {
                return message
            }
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}
