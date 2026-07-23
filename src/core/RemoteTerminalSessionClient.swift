import Foundation

public enum RemoteTerminalEvent: Equatable, Sendable {
    case output(String)
    case history(String)
    case presence(Int)
}

public enum RemoteTerminalSessionError: Error, Equatable, LocalizedError {
    case invalidResponse
    case sequenceGap(expected: UInt64)
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Mac returned an invalid terminal message."
        case .sequenceGap:
            "The relay terminal stream was interrupted."
        case .remote(let message):
            message
        }
    }
}

public actor RemoteTerminalSessionClient {
    private let macID: String
    private let sessionID: String
    private let requestID: String
    private let transport: any RemoteRelayTransport
    private var sequenceTracker = RemoteSequenceTracker()

    public init(
        macID: String,
        sessionID: String,
        requestID: String = UUID().uuidString,
        transport: any RemoteRelayTransport
    ) {
        self.macID = macID
        self.sessionID = sessionID
        self.requestID = requestID
        self.transport = transport
    }

    public func connect(peerID: String) async throws {
        try await transport.connect(peerID: peerID)
        sequenceTracker.reset(to: nil)
        try await send(.attach, clientRole: .mac)
    }

    public func reconnect(peerID: String) async throws {
        await transport.disconnect()
        try await connect(peerID: peerID)
    }

    public func receive() async throws -> RemoteTerminalEvent {
        while !Task.isCancelled {
            let data = try await transport.receive()
            let message = try JSONDecoder().decode(RemoteMessage.self, from: data)
            guard message.version == RemoteMessage.currentVersion,
                  message.requestID == requestID,
                  message.macID == macID,
                  message.sessionID == nil || message.sessionID == sessionID else { continue }
            switch message.kind {
            case .terminalEvent:
                guard let sequence = message.sequence,
                      let payload = message.payload,
                      let text = String(data: payload, encoding: .utf8)
                else { throw RemoteTerminalSessionError.invalidResponse }
                switch sequenceTracker.accept(sequence) {
                case .accepted:
                    return message.isHistory == true ? .history(text) : .output(text)
                case .duplicate:
                    continue
                case .gap(let expected):
                    throw RemoteTerminalSessionError.sequenceGap(expected: expected)
                }
            case .presence:
                guard let payload = message.payload,
                      let text = String(data: payload, encoding: .utf8),
                      let count = Int(text)
                else { throw RemoteTerminalSessionError.invalidResponse }
                return .presence(count)
            case .error:
                let text = message.payload.flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? "Remote session failed"
                throw RemoteTerminalSessionError.remote(text)
            default:
                continue
            }
        }
        throw CancellationError()
    }

    public func sendInput(_ text: String) async throws {
        try await send(.input, payload: Data(text.utf8))
    }

    public func interrupt() async throws {
        try await send(.interrupt)
    }

    public func resize(rows: UInt16, cols: UInt16) async throws {
        try await send(
            .resize,
            payload: JSONEncoder().encode(RemoteTerminalSize(rows: rows, cols: cols))
        )
    }

    public func clearHistory() async throws {
        try await send(.clearHistory)
    }

    public func updateState(_ state: RemoteSessionState) async throws {
        try await send(.updateState, payload: JSONEncoder().encode(state))
    }

    public func kill() async throws {
        try await send(.kill)
    }

    public func disconnect() async {
        try? await send(.detach)
        await transport.disconnect()
    }

    private func send(
        _ kind: RemoteMessageKind,
        payload: Data? = nil,
        clientRole: RemoteClientRole? = nil
    ) async throws {
        try await transport.send(JSONEncoder().encode(RemoteMessage(
            kind: kind,
            requestID: requestID,
            macID: macID,
            sessionID: sessionID,
            payload: payload,
            clientRole: clientRole
        )))
    }
}
