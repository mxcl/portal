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
                    macID: macID,
                    sessionID: sessionRef.sessionID,
                    transport: try RelayClient(endpoint: endpoint, rootKeyData: key)
                )
                self.client = client
                completionProvider.connect(client)
                try await client.connect(peerID: peerID)
                completion(.success(()))
                onReady?(false)
                await receive(from: client, peerID: peerID)
            } catch is CancellationError {
                return
            } catch {
                completion(.failure(error))
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        send { try await $0.resize(rows: rows, cols: cols) }
    }

    func isCanonicalInputModeEnabled() -> Bool? {
        nil
    }

    func sendInterrupt() {
        send { try await $0.interrupt() }
    }

    func clearHistory() {
        send { try await $0.clearHistory() }
    }

    func write(_ string: String, suppressEcho: Bool = false) {
        send { try await $0.sendInput(string) }
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
        send { try await $0.updateState(state) }
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
        receiveTask?.cancel()
        completionProvider.disconnect()
        let previous = pendingSend
        pendingSend = Task { [weak self] in
            await previous?.value
            guard let self, let client else { return }
            try? await client.kill()
            await client.disconnect()
            self.client = nil
        }
    }

    static func killDetached(_ sessionRef: SessionRef) async throws {
        guard case .relayMac(let macID) = sessionRef.location else { return }
        let endpoint = try MacRemoteAccessController.relayEndpoint()
        let key = try ICloudKeychainRootKey().loadOrCreate()
        let client = RemoteTerminalSessionClient(
            macID: macID,
            sessionID: sessionRef.sessionID,
            transport: try RelayClient(endpoint: endpoint, rootKeyData: key)
        )
        try await client.connect(peerID: MacRemoteAccessController.macID())
        try await client.kill()
        await client.disconnect()
    }

    private func receive(
        from client: RemoteTerminalSessionClient,
        peerID: String
    ) async {
        var retryDelay = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                switch try await client.receive() {
                case .output(let text):
                    onOutput?(text)
                case .history(let text):
                    onHistoryOutput?(text)
                case .presence(let count):
                    onPresence?(count)
                case .capabilities(let values):
                    completionProvider.enable(values)
                }
                retryDelay = .seconds(1)
            } catch is CancellationError {
                return
            } catch RemoteTerminalSessionError.remote(let message) {
                onOutput?("\r\n\(message)\r\n")
                onExit?(-1)
                return
            } catch {
                completionProvider.disconnect()
                try? await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(30))
                do {
                    try await client.reconnect(peerID: peerID)
                    completionProvider.connect(client)
                } catch {
                    continue
                }
            }
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
