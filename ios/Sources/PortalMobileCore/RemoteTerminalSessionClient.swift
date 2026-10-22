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
    case historySnapshot(RemoteTerminalHistory)
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
    case peerRestarted
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
        case .peerRestarted:
            "The SSH connection restarted."
        case .invalidResponse:
            "The Mac returned an invalid terminal message."
        case .sequenceGap:
            "The SSH terminal stream was interrupted."
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
    private let peerID: String
    private let sessionID: String
    private let host: SSHHost
    private var connection: SSHSessionConnection?
    private var attached = false
    private var stopped = false
    private var running = false

    public init(peerID: String, sessionID: String, host: SSHHost) {
        self.peerID = peerID
        self.sessionID = sessionID
        self.host = host
    }

    public func run(_ handle: @escaping @Sendable (RemoteTerminalEvent) async -> Void) async throws {
        guard !running else { throw RemoteTerminalSessionError.alreadyRunning }
        running = true
        defer { running = false; attached = false; connection = nil }
        let connection = SSHSessionConnection(host: host)
        self.connection = connection
        await handle(.connection(.connecting))
        try await connection.run(.joinV2(version: SessionWireProtocol.currentVersion, role: .phone,
            clientID: peerID, sessionID: sessionID)) { event in
                try await self.handle(event, emit: handle)
            }
    }

    private func handle(_ event: SessionWireProtocol.ServerEvent,
                        emit: @escaping @Sendable (RemoteTerminalEvent) async -> Void) async throws -> Bool {
        guard !stopped else { return false }
        switch event {
        case .ready:
            attached = true
            await emit(.connection(.attached))
            await emit(.capabilitiesChanged([RemoteCapabilities.completion, RemoteCapabilities.history]))
        case .output(let text), .sequencedOutput(_, let text): await emit(.output(Data(text.utf8)))
        case .history(let text), .historyPage(_, _, _, let text): await emit(.history(Data(text.utf8)))
        case .snapshot(_, let rows, let cols, let contents):
            await emit(.snapshot(RemoteTerminalSnapshot(rows: rows, cols: cols, contents: Data(contents.utf8))))
        case .geometry(let rows, let cols): await emit(.size(RemoteTerminalSize(rows: rows, cols: cols)))
        case .presence(let count): await emit(.presence(count))
        case .notFound: throw RemoteTerminalSessionError.remote("This session has ended. Refresh the session list.")
        case .exit: return false
        case .protocolVersion(let version):
            guard version == SessionWireProtocol.currentVersion else { throw SSHSessionError.incompatibleProtocol }
        default: break
        }
        return true
    }

    public func send(_ command: RemoteTerminalCommand) async throws {
        guard attached, let connection else { throw RemoteTerminalSessionError.notAttached }
        let wire: SessionWireProtocol.ClientCommand
        switch command {
        case .input(let data): wire = .input(data)
        case .submit(let command): wire = .input(Data(PortalCommandEnvelope.shellScript(for: command).utf8))
        case .interrupt: wire = .interrupt
        case .resize(let size): wire = .resize(rows: size.rows, cols: size.cols)
        case .clearHistory: wire = .clearHistory
        case .updateState(let state):
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            wire = .state(try encoder.encode(state))
        case .kill: wire = .killAttachedSession
        }
        do { try await connection.send(wire) }
        catch {
            attached = false
            await connection.close()
            throw RemoteTerminalSessionError.deliveryUnknown
        }
    }

    public func complete(operation: RemoteCompletionOperation, payload: Data, timeout: TimeInterval) async throws -> Data {
        guard attached else { throw RemoteTerminalSessionError.notAttached }
        let request = SSHSessionConnection(host: host)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { try await request.complete(operation: operation, payload: payload) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(min(max(timeout, 0.001), 60) * 1_000_000_000))
                    await request.close()
                    throw RemoteTerminalSessionError.completionTimedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { Task { await request.close() } }
    }

    public func disconnect() async {
        stopped = true
        attached = false
        await connection?.close()
    }
}
