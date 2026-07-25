import Foundation
import Testing
@testable import VaulttyCore

@Suite("Remote terminal session client")
struct RemoteTerminalSessionClientTests {
    @Test("Mac attach preserves ordered history")
    func macHistory() async throws {
        let (client, transport) = makeClient(role: .mac)
        let running = run(client)
        var events = running.events.makeAsyncIterator()

        #expect(await events.next() == .connection(.connecting))
        let attach = try await transport.waitForMessage(kind: .attach)
        #expect(attach.clientRole == .mac)
        #expect(await events.next() == .connection(.attached))

        try await transport.enqueue(RemoteMessage(
            kind: .terminalEvent,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            sequence: 1,
            payload: Data("history".utf8),
            isHistory: true
        ))
        #expect(await events.next() == .history(Data("history".utf8)))

        await client.disconnect()
        try await running.task.value
    }

    @Test("phone attach exposes snapshots and terminal size")
    func phoneSnapshot() async throws {
        let (client, transport) = makeClient(role: .phone)
        let running = run(client)
        var events = running.events.makeAsyncIterator()

        _ = await events.next()
        let attach = try await transport.waitForMessage(kind: .attach)
        #expect(attach.clientRole == .phone)
        _ = await events.next()

        let snapshot = RemoteTerminalSnapshot(
            rows: 24,
            cols: 80,
            contents: Data("screen".utf8)
        )
        try await transport.enqueue(RemoteMessage(
            kind: .terminalSnapshot,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(snapshot)
        ))
        try await transport.enqueue(RemoteMessage(
            kind: .resize,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: try JSONEncoder().encode(RemoteTerminalSize(rows: 30, cols: 100))
        ))

        #expect(await events.next() == .snapshot(snapshot))
        #expect(await events.next() == .size(RemoteTerminalSize(rows: 30, cols: 100)))

        await client.disconnect()
        try await running.task.value
    }

    @Test("sequence gaps reconnect and re-attach inside the module")
    func sequenceGapRecovers() async throws {
        let (client, transport) = makeClient(role: .phone)
        let running = run(client)
        var events = running.events.makeAsyncIterator()
        _ = await events.next()
        _ = try await transport.waitForMessage(kind: .attach)
        _ = await events.next()

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

        #expect(await events.next() == .output(Data("output".utf8)))
        #expect(await events.next() == .connection(.reconnecting))
        _ = try await transport.waitForMessage(kind: .attach, occurrence: 2)
        #expect(await events.next() == .connection(.attached))

        try await transport.enqueue(RemoteMessage(
            kind: .terminalEvent,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            sequence: 1,
            payload: Data("replayed".utf8)
        ))
        #expect(await events.next() == .output(Data("replayed".utf8)))

        await client.disconnect()
        try await running.task.value
    }

    @Test("commands fail rather than queue while detached")
    func detachedCommandFails() async throws {
        let (client, _) = makeClient(role: .phone)
        await #expect(throws: RemoteTerminalSessionError.notAttached) {
            try await client.send(.input(Data("unsafe to replay".utf8)))
        }
    }

    @Test("completion is capability-gated, correlated, and cancellable")
    func completionLifecycle() async throws {
        let (client, transport) = makeClient(role: .mac)
        let running = run(client)
        var events = running.events.makeAsyncIterator()
        _ = await events.next()
        _ = try await transport.waitForMessage(kind: .attach)
        _ = await events.next()

        await #expect(throws: RemoteTerminalSessionError.completionUnavailable) {
            try await client.complete(
                operation: .completeCommands,
                payload: Data(),
                timeout: 1
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
        #expect(await events.next() == .completionAvailabilityChanged(true))

        await #expect(throws: RemoteTerminalSessionError.invalidResponse) {
            try await client.complete(
                operation: .runGenerator,
                payload: Data(
                    repeating: 0,
                    count: RemoteCompletionRequest.maximumPayloadSize + 1
                ),
                timeout: 1
            )
        }
        #expect(await transport.messageCount(kind: .completionRequest) == 0)

        let completion = Task {
            try await client.complete(
                operation: .completeCommands,
                payload: Data("request".utf8),
                timeout: 1
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

        #expect(await events.next() == .presence(1))
        #expect(try await completion.value == Data("response".utf8))

        await #expect(throws: RemoteTerminalSessionError.completionTimedOut) {
            try await client.complete(
                operation: .completePath,
                payload: Data(),
                timeout: 0.001
            )
        }
        _ = try await transport.waitForMessage(kind: .completionCancel)

        let cancelled = Task {
            try await client.complete(
                operation: .completePath,
                payload: Data(),
                timeout: 1
            )
        }
        _ = try await transport.waitForMessage(kind: .completionRequest, occurrence: 3)
        cancelled.cancel()
        _ = try await transport.waitForMessage(kind: .completionCancel, occurrence: 2)
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await client.disconnect()
        try await running.task.value
    }

    @Test("matching remote errors are terminal")
    func remoteErrorEndsRun() async throws {
        let (client, transport) = makeClient(role: .phone)
        let running = run(client)
        var events = running.events.makeAsyncIterator()
        _ = await events.next()
        _ = try await transport.waitForMessage(kind: .attach)
        _ = await events.next()

        try await transport.enqueue(RemoteMessage(
            kind: .error,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            payload: Data("gone".utf8)
        ))

        await #expect(throws: RemoteTerminalSessionError.remote("gone")) {
            try await running.task.value
        }
    }

    private func makeClient(
        role: RemoteClientRole
    ) -> (RemoteTerminalSessionClient, FakeTerminalTransport) {
        let transport = FakeTerminalTransport()
        return (
            RemoteTerminalSessionClient(
                peerID: "peer",
                macID: "mac",
                sessionID: "session",
                role: role,
                requestID: "request",
                transport: transport
            ),
            transport
        )
    }

    private func run(
        _ client: RemoteTerminalSessionClient
    ) -> (events: AsyncStream<RemoteTerminalEvent>, task: Task<Void, any Error>) {
        let (events, continuation) = AsyncStream.makeStream(of: RemoteTerminalEvent.self)
        let task = Task {
            defer { continuation.finish() }
            try await client.run { continuation.yield($0) }
        }
        return (events, task)
    }
}

private actor FakeTerminalTransport: RemoteRelayTransport {
    private var responses: [Data] = []
    private var isConnected = false
    private(set) var sentMessages: [RemoteMessage] = []

    func connect(peerID: String) async throws {
        isConnected = true
    }

    func send(_ plaintext: Data) async throws {
        guard isConnected else { throw FakeTransportError.disconnected }
        sentMessages.append(try JSONDecoder().decode(RemoteMessage.self, from: plaintext))
    }

    func receive() async throws -> Data {
        while responses.isEmpty {
            try Task.checkCancellation()
            guard isConnected else { throw FakeTransportError.disconnected }
            await Task.yield()
        }
        return responses.removeFirst()
    }

    func disconnect() async {
        isConnected = false
    }

    func enqueue(_ message: RemoteMessage) throws {
        responses.append(try JSONEncoder().encode(message))
    }

    func waitForMessage(
        kind: RemoteMessageKind,
        occurrence: Int = 1
    ) async throws -> RemoteMessage {
        while true {
            let matches = sentMessages.filter { $0.kind == kind }
            if matches.count >= occurrence {
                return matches[occurrence - 1]
            }
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func messageCount(kind: RemoteMessageKind) -> Int {
        sentMessages.count { $0.kind == kind }
    }
}

private enum FakeTransportError: Error {
    case disconnected
}
