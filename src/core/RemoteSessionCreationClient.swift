import Foundation

public protocol RemoteRelayTransport: Sendable {
    func connect(peerID: String) async throws
    func send(_ plaintext: Data) async throws
    func receive() async throws -> Data
    func disconnect() async
}

extension RelayClient: RemoteRelayTransport {}

public enum RemoteSessionCreationError: Error, Equatable, LocalizedError {
    case timedOut
    case invalidResponse
    case remote(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            "The Mac did not respond. Make sure Vaultty is running and up to date."
        case .invalidResponse:
            "The Mac returned an invalid session."
        case .remote(let message):
            message
        }
    }
}

public struct RemoteSessionCreationClient: Sendable {
    public typealias TransportFactory = @Sendable () throws -> any RemoteRelayTransport

    private let makeTransport: TransportFactory
    private let timeoutNanoseconds: UInt64

    public init(
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        makeTransport: @escaping TransportFactory
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.makeTransport = makeTransport
    }

    public func createSession(
        on macID: String,
        sessionID: String,
        peerID: String
    ) async throws -> RemoteCatalogSession {
        let transport = try makeTransport()
        do {
            try await transport.connect(peerID: peerID)
            let request = RemoteMessage(
                kind: .createSession,
                requestID: UUID().uuidString,
                macID: macID,
                sessionID: sessionID
            )
            try await transport.send(JSONEncoder().encode(request))
            let session = try await response(
                to: request,
                from: transport
            )
            await transport.disconnect()
            return session
        } catch {
            await transport.disconnect()
            throw error
        }
    }

    private func response(
        to request: RemoteMessage,
        from transport: any RemoteRelayTransport
    ) async throws -> RemoteCatalogSession {
        try await withThrowingTaskGroup(of: RemoteCatalogSession.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let data = try await transport.receive()
                    let message = try JSONDecoder().decode(RemoteMessage.self, from: data)
                    guard message.version == RemoteMessage.currentVersion,
                          message.requestID == request.requestID,
                          message.macID == request.macID else { continue }
                    switch message.kind {
                    case .sessionCreated:
                        guard message.sessionID == request.sessionID,
                              let payload = message.payload,
                              let session = try? JSONDecoder().decode(
                                RemoteCatalogSession.self,
                                from: payload
                              ),
                              session.sessionID == request.sessionID
                        else { throw RemoteSessionCreationError.invalidResponse }
                        return session
                    case .error:
                        let text = message.payload.flatMap {
                            String(data: $0, encoding: .utf8)
                        } ?? "The Mac could not start a session."
                        throw RemoteSessionCreationError.remote(text)
                    default:
                        continue
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                await transport.disconnect()
                throw RemoteSessionCreationError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RemoteSessionCreationError.invalidResponse
            }
            return result
        }
    }
}
