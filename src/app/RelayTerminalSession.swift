import Foundation

@MainActor
final class RelayTerminalSession: TerminalSession {
    var onOutput: ((String) -> Void)?
    var onHistoryOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPresence: ((Int) -> Void)?
    let completionProvider = RelayCompletionProvider()

    private let sessionRef: SessionRef
    private let createsSession: Bool
    private var client: RemoteTerminalSessionClient?
    private var receiveTask: Task<Void, Never>?
    private var pendingSend: Task<Void, Never>?
    private var startCompletion: ((Result<Void, Error>) -> Void)?

    init(sessionRef: SessionRef, createsSession: Bool = false) {
        self.sessionRef = sessionRef
        self.createsSession = createsSession
    }

    deinit {
        receiveTask?.cancel()
        pendingSend?.cancel()
    }

    func start(
        shellPath: String,
        environment: [String: String],
        workingDirectory: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard case .relayMac(let macID) = sessionRef.location else {
            completion(.failure(RelayClientError.invalidEndpoint))
            return
        }
        startCompletion = completion
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = try MacRemoteAccessController.relayEndpoint()
                let key = try ICloudKeychainRootKey().loadOrCreate()
                let peerID = MacRemoteAccessController.macID()
                if createsSession {
                    let creator = RemoteSessionCreationClient {
                        try RelayClient(endpoint: endpoint, rootKeyData: key)
                    }
                    _ = try await creator.createSession(
                        on: macID,
                        sessionID: sessionRef.sessionID,
                        peerID: peerID
                    )
                }
                let client = RemoteTerminalSessionClient(
                    peerID: peerID,
                    macID: macID,
                    sessionID: sessionRef.sessionID,
                    role: .mac,
                    transport: try RelayClient(endpoint: endpoint, rootKeyData: key)
                )
                self.client = client
                completionProvider.connect(client)
                try await client.run { [weak self] event in
                    await self?.receive(event)
                }
            } catch is CancellationError {
                return
            } catch {
                fail(error)
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        send { try await $0.send(.resize(RemoteTerminalSize(rows: rows, cols: cols))) }
    }

    func isCanonicalInputModeEnabled() -> Bool? {
        nil
    }

    func sendInterrupt() {
        send { try await $0.send(.interrupt) }
    }

    func clearHistory() {
        send { try await $0.send(.clearHistory) }
    }

    func write(_ string: String, suppressEcho: Bool = false) {
        send { try await $0.send(.input(Data(string.utf8))) }
    }

    func updateState(
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        runningCommand: String?,
        commandHistory: [String]
    ) {
        let state = RemoteSessionState(
            title: title,
            cwd: cwd,
            createdAt: createdAt,
            commandCount: commandCount,
            runningCommand: runningCommand,
            commandHistory: commandHistory
        )
        send { try await $0.send(.updateState(state)) }
    }

    func stop() {
        receiveTask?.cancel()
        pendingSend?.cancel()
        completionProvider.disconnect()
        guard let client else { return }
        Task { await client.disconnect() }
        self.client = nil
    }

    func kill() {
        completionProvider.disconnect()
        let previous = pendingSend
        pendingSend = Task { [weak self] in
            await previous?.value
            guard let self, let client else { return }
            try? await client.send(.kill)
            receiveTask?.cancel()
            self.client = nil
        }
    }

    static func killDetached(_ sessionRef: SessionRef) async throws {
        guard case .relayMac(let macID) = sessionRef.location else { return }
        let endpoint = try MacRemoteAccessController.relayEndpoint()
        let key = try ICloudKeychainRootKey().loadOrCreate()
        let client = RemoteTerminalSessionClient(
            peerID: MacRemoteAccessController.macID(),
            macID: macID,
            sessionID: sessionRef.sessionID,
            role: .mac,
            transport: try RelayClient(endpoint: endpoint, rootKeyData: key)
        )
        let (events, continuation) = AsyncStream.makeStream(of: RemoteTerminalEvent.self)
        let runTask = Task {
            defer { continuation.finish() }
            try await client.run { continuation.yield($0) }
        }
        defer { runTask.cancel() }
        for await event in events {
            guard event == .connection(.attached) else { continue }
            try await client.send(.kill)
            break
        }
        _ = try await runTask.value
    }

    private func receive(_ event: RemoteTerminalEvent) {
        switch event {
        case .connection(.attached):
            if let completion = startCompletion {
                startCompletion = nil
                completion(.success(()))
                onReady?(false)
            }
        case .connection(.reconnecting):
            completionProvider.disconnect()
            if let client {
                completionProvider.connect(client)
            }
        case .connection(.connecting):
            break
        case .output(let data):
            onOutput?(String(decoding: data, as: UTF8.self))
        case .history(let data):
            onHistoryOutput?(String(decoding: data, as: UTF8.self))
        case .presence(let count):
            onPresence?(count)
        case .capabilitiesChanged(let capabilities):
            if !capabilities.isEmpty {
                completionProvider.enable(capabilities)
            } else {
                completionProvider.disconnect()
                if let client {
                    completionProvider.connect(client)
                }
            }
        case .snapshot, .size:
            break
        }
    }

    private func fail(_ error: Error) {
        if let completion = startCompletion {
            startCompletion = nil
            completion(.failure(error))
        } else {
            if case RemoteTerminalSessionError.remote(let message) = error {
                onOutput?("\r\n\(message)\r\n")
            }
            onExit?(-1)
        }
    }

    private func send(
        _ operation: @escaping @Sendable (RemoteTerminalSessionClient) async throws -> Void
    ) {
        let previous = pendingSend
        pendingSend = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let client = self?.client else { return }
            try? await operation(client)
        }
    }
}
