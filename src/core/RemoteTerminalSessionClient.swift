import Foundation

public enum RemoteTerminalConnectionState: Equatable, Sendable {
    case connecting
    case attached
    case reconnecting
}

public enum RemoteTerminalEvent: Equatable, Sendable {
    case connection(RemoteTerminalConnectionState)
    case streamReset
    case output(Data)
    case history(Data)
    case snapshot(RemoteTerminalSnapshot)
    case size(RemoteTerminalSize)
    case presence(Int)
    case capabilitiesChanged(Set<String>)
}

public enum RemoteTerminalCommand: Equatable, Sendable {
    case input(Data)
    case submit(String)
    case interrupt
    case resize(RemoteTerminalSize)
    case clearHistory
    case updateState(RemoteSessionState)
    case kill
}

public enum RemoteTerminalSessionError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case notAttached
    case deliveryUnknown
    case invalidResponse
    case sequenceGap(expected: UInt64)
    case completionUnavailable
    case completionTimedOut
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "The remote terminal session is already running."
        case .notAttached:
            "The remote terminal session is not attached."
        case .deliveryUnknown:
            "The remote terminal command may not have been delivered."
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
    private enum State: Equatable {
        case idle
        case connecting
        case attached
        case reconnecting
        case stopping
    }

    private let peerID: String
    private let macID: String
    private let sessionID: String
    private let requestID: String
    private let role: RemoteClientRole
    private let transport: any RemoteRelayTransport
    private var state = State.idle
    private var isRunning = false
    private var shouldStop = false
    private var resetsStreamOnRecovery = false
    private var sequenceTracker = RemoteSequenceTracker()
    private var capabilities = Set<String>()
    private var completionWaiters: [
        String: CheckedContinuation<Data, any Error>
    ] = [:]
    private var completionTimeouts: [String: Task<Void, Never>] = [:]

    public init(
        peerID: String,
        macID: String,
        sessionID: String,
        role: RemoteClientRole,
        requestID: String = UUID().uuidString,
        transport: any RemoteRelayTransport
    ) {
        self.peerID = peerID
        self.macID = macID
        self.sessionID = sessionID
        self.role = role
        self.requestID = requestID
        self.transport = transport
    }

    public func run(
        _ handle: @escaping @Sendable (RemoteTerminalEvent) async -> Void
    ) async throws {
        guard !isRunning else { throw RemoteTerminalSessionError.alreadyRunning }
        isRunning = true
        shouldStop = false
        state = .connecting
        await handle(.connection(.connecting))
        var retryDelayNanoseconds: UInt64 = 1_000_000_000

        do {
            while !shouldStop, !Task.isCancelled {
                do {
                    try await attach()
                    guard !shouldStop, !Task.isCancelled else { break }
                    state = .attached
                    await handle(.connection(.attached))

                    while !shouldStop, !Task.isCancelled {
                        if let event = try await receiveEvent() {
                            retryDelayNanoseconds = 1_000_000_000
                            await handle(event)
                        }
                    }
                } catch is CancellationError {
                    break
                } catch let error as RemoteTerminalSessionError {
                    if case .remote = error { throw error }
                    guard !shouldStop else { break }
                    let resetStream = await recover(
                        handle: handle,
                        retryDelayNanoseconds: retryDelayNanoseconds
                    )
                    retryDelayNanoseconds = resetStream ? 1_000_000_000 : min(
                        retryDelayNanoseconds * 2, 30_000_000_000
                    )
                } catch {
                    guard !shouldStop else { break }
                    let resetStream = await recover(
                        handle: handle,
                        retryDelayNanoseconds: retryDelayNanoseconds
                    )
                    retryDelayNanoseconds = resetStream ? 1_000_000_000 : min(
                        retryDelayNanoseconds * 2, 30_000_000_000
                    )
                }
            }
        } catch {
            await finishRun()
            throw error
        }
        await finishRun()
    }

    public func send(_ command: RemoteTerminalCommand) async throws {
        guard state == .attached else { throw RemoteTerminalSessionError.notAttached }
        do {
            switch command {
            case .input(let data):
                try await sendMessage(.input, payload: data)
            case .submit(let command):
                try await sendMessage(.submit, payload: Data(command.utf8))
            case .interrupt:
                if try await sendMessageUrgently(.interrupt) {
                    resetsStreamOnRecovery = true
                    state = .reconnecting
                    failAllCompletions()
                    await transport.disconnect()
                }
            case .resize(let size):
                try await sendMessage(.resize, payload: JSONEncoder().encode(size))
            case .clearHistory:
                try await sendMessage(.clearHistory)
            case .updateState(let state):
                try await sendMessage(.updateState, payload: JSONEncoder().encode(state))
            case .kill:
                try await sendMessage(.kill)
                await disconnect()
            }
        } catch {
            state = .reconnecting
            failAllCompletions()
            await transport.disconnect()
            throw RemoteTerminalSessionError.deliveryUnknown
        }
    }

    public func complete(
        operation: RemoteCompletionOperation,
        payload: Data,
        timeout: TimeInterval
    ) async throws -> Data {
        guard state == .attached else { throw RemoteTerminalSessionError.notAttached }
        guard capabilities.contains(operation.requiredCapability) else {
            throw RemoteTerminalSessionError.completionUnavailable
        }
        guard payload.count <= RemoteCompletionRequest.maximumPayloadSize else {
            throw RemoteTerminalSessionError.invalidResponse
        }

        let operationID = UUID().uuidString
        let timeoutNanoseconds = UInt64(
            min(max(timeout, 0.001), 60) * 1_000_000_000
        )
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
                        try await self.sendMessage(
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
                            error: RemoteTerminalSessionError.deliveryUnknown,
                            sendsCancellation: false
                        )
                        await self.deliveryFailed()
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
        guard state != .idle else { return }
        shouldStop = true
        let wasAttached = state == .attached
        state = .stopping
        failAllCompletions()
        if wasAttached {
            try? await sendMessage(.detach)
        }
        await transport.disconnect()
    }

    private func attach() async throws {
        sequenceTracker.reset(to: nil)
        capabilities.removeAll()
        try await transport.connect(peerID: peerID)
        try await sendMessage(.attach, clientRole: role)
    }

    private func receiveEvent() async throws -> RemoteTerminalEvent? {
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
                      let payload = message.payload
                else { throw RemoteTerminalSessionError.invalidResponse }
                switch sequenceTracker.accept(sequence) {
                case .accepted:
                    return message.isHistory == true ? .history(payload) : .output(payload)
                case .duplicate:
                    continue
                case .gap(let expected):
                    throw RemoteTerminalSessionError.sequenceGap(expected: expected)
                }
            case .terminalSnapshot:
                guard let payload = message.payload,
                      let snapshot = try? JSONDecoder().decode(
                        RemoteTerminalSnapshot.self,
                        from: payload
                      )
                else { throw RemoteTerminalSessionError.invalidResponse }
                return .snapshot(snapshot)
            case .resize:
                guard let payload = message.payload,
                      let size = try? JSONDecoder().decode(RemoteTerminalSize.self, from: payload)
                else { throw RemoteTerminalSessionError.invalidResponse }
                return .size(size)
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
                return .capabilitiesChanged(capabilities)
            case .completionResponse:
                guard let payload = message.payload,
                      let response = try? JSONDecoder().decode(
                        RemoteCompletionResponse.self,
                        from: payload
                      )
                else { throw RemoteTerminalSessionError.invalidResponse }
                resolveCompletion(response)
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

    private func recover(
        handle: @escaping @Sendable (RemoteTerminalEvent) async -> Void,
        retryDelayNanoseconds: UInt64
    ) async -> Bool {
        let resetsStream = resetsStreamOnRecovery
        resetsStreamOnRecovery = false
        state = .reconnecting
        let previousCapabilities = capabilities
        capabilities.removeAll()
        failAllCompletions()
        await transport.disconnect()
        if !previousCapabilities.isEmpty {
            await handle(.capabilitiesChanged([]))
        }
        if resetsStream {
            await handle(.streamReset)
        }
        await handle(.connection(.reconnecting))
        if !resetsStream {
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
        return resetsStream
    }

    private func deliveryFailed() async {
        guard state == .attached else { return }
        state = .reconnecting
        failAllCompletions()
        await transport.disconnect()
    }

    private func finishRun() async {
        let wasAttached = state == .attached
        shouldStop = true
        state = .stopping
        failAllCompletions()
        if wasAttached {
            try? await sendMessage(.detach)
        }
        await transport.disconnect()
        state = .idle
        isRunning = false
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
           state == .attached,
           let payload = try? JSONEncoder().encode(
               RemoteCompletionCancellation(operationID: operationID)
           ) {
            try? await sendMessage(.completionCancel, payload: payload)
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

    private func sendMessage(
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

    private func sendMessageUrgently(_ kind: RemoteMessageKind) async throws -> Bool {
        try await transport.sendUrgently(JSONEncoder().encode(RemoteMessage(
            kind: kind,
            requestID: requestID,
            macID: macID,
            sessionID: sessionID
        )))
    }
}
