import Foundation

public enum RemoteTerminalEvent: Equatable, Sendable {
    case output(String)
    case history(String)
    case presence(Int)
    case capabilities(Set<String>)
}

public enum RemoteTerminalSessionError: Error, Equatable, LocalizedError {
    case invalidResponse
    case sequenceGap(expected: UInt64)
    case completionUnavailable
    case completionTimedOut
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Mac returned an invalid terminal message."
        case .sequenceGap:
            "The relay terminal stream was interrupted."
        case .completionUnavailable:
            "The remote Mac does not support completion."
        case .completionTimedOut:
            "Remote completion timed out."
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
    private var capabilities = Set<String>()
    private var completionWaiters: [
        String: CheckedContinuation<Data, any Error>
    ] = [:]
    private var completionTimeouts: [String: Task<Void, Never>] = [:]

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
        capabilities.removeAll()
        try await send(.attach, clientRole: .mac)
    }

    public func reconnect(peerID: String) async throws {
        failAllCompletions()
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
            case .capabilities:
                guard let payload = message.payload,
                      let advertised = try? JSONDecoder().decode(
                        RemoteCapabilities.self,
                        from: payload
                      )
                else { throw RemoteTerminalSessionError.invalidResponse }
                capabilities = Set(advertised.values)
                return .capabilities(capabilities)
            case .completionResponse:
                guard let payload = message.payload,
                      let response = try? JSONDecoder().decode(
                        RemoteCompletionResponse.self,
                        from: payload
                      )
                else { throw RemoteTerminalSessionError.invalidResponse }
                resolveCompletion(response)
                continue
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

    public func complete(
        operation: RemoteCompletionOperation,
        payload: Data,
        timeoutNanoseconds: UInt64
    ) async throws -> Data {
        guard capabilities.contains(RemoteCapabilities.relayCompletion) else {
            throw RemoteTerminalSessionError.completionUnavailable
        }
        guard payload.count <= RemoteCompletionRequest.maximumPayloadSize else {
            throw RemoteTerminalSessionError.invalidResponse
        }

        let operationID = UUID().uuidString
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completionWaiters[operationID] = continuation
                completionTimeouts[operationID] = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self?.failCompletion(
                        operationID,
                        error: RemoteTerminalSessionError.completionTimedOut,
                        sendsCancellation: true
                    )
                }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.send(
                            .completionRequest,
                            payload: JSONEncoder().encode(RemoteCompletionRequest(
                                operationID: operationID,
                                operation: operation,
                                payload: payload
                            ))
                        )
                    } catch {
                        await self.failCompletion(
                            operationID,
                            error: error,
                            sendsCancellation: false
                        )
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failCompletion(
                    operationID,
                    error: CancellationError(),
                    sendsCancellation: true
                )
            }
        }
    }

    public func disconnect() async {
        failAllCompletions()
        try? await send(.detach)
        await transport.disconnect()
    }

    private func resolveCompletion(_ response: RemoteCompletionResponse) {
        guard let continuation = completionWaiters.removeValue(
            forKey: response.operationID
        ) else { return }
        completionTimeouts.removeValue(forKey: response.operationID)?.cancel()
        if let error = response.error {
            continuation.resume(throwing: RemoteTerminalSessionError.remote(error))
        } else if let payload = response.payload,
                  payload.count <= RemoteCompletionResponse.maximumPayloadSize {
            continuation.resume(returning: payload)
        } else {
            continuation.resume(throwing: RemoteTerminalSessionError.invalidResponse)
        }
    }

    private func failCompletion(
        _ operationID: String,
        error: any Error,
        sendsCancellation: Bool
    ) async {
        guard let continuation = completionWaiters.removeValue(forKey: operationID) else {
            return
        }
        completionTimeouts.removeValue(forKey: operationID)?.cancel()
        continuation.resume(throwing: error)
        if sendsCancellation,
           let payload = try? JSONEncoder().encode(
            RemoteCompletionCancellation(operationID: operationID)
           ) {
            try? await send(.completionCancel, payload: payload)
        }
    }

    private func failAllCompletions() {
        let waiters = completionWaiters
        completionWaiters.removeAll()
        completionTimeouts.values.forEach { $0.cancel() }
        completionTimeouts.removeAll()
        for continuation in waiters.values {
            continuation.resume(throwing: CancellationError())
        }
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
