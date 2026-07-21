import Foundation

final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

public enum RelayClientError: Error, Equatable {
    case invalidEndpoint
    case unexpectedMessage
    case invalidResponse(Int)
    case catalogChanged
}

public actor RelayClient {
    private let endpoint: URL
    private let address: RelayAddress
    private let crypto: RelayCrypto
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?

    public init(endpoint: URL, rootKeyData: Data) throws {
        self.endpoint = endpoint
        crypto = try RelayCrypto(rootKeyData: rootKeyData)
        address = crypto.address
    }

    public func connect(peerID: String) throws {
        guard socket == nil else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.scheme = endpoint.scheme == "http" ? "ws" : "wss"
        components?.path = endpoint.path + "/v1/connect/\(address.room)/\(peerID)"
        guard let url = components?.url else {
            throw RelayClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(address.credential)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: request)
        self.session = session
        self.socket = socket
        socket.resume()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    try Task.checkCancellation()
                    try await self?.sendPing()
                } catch {
                    return
                }
            }
        }
    }

    public func send(_ plaintext: Data) async throws {
        guard let socket else { throw RelayClientError.invalidEndpoint }
        let envelope = try crypto.seal(plaintext, purpose: "transport")
        try await socket.send(.data(JSONEncoder().encode(envelope)))
    }

    public func receive() async throws -> Data {
        guard let socket else { throw RelayClientError.invalidEndpoint }
        let message = try await socket.receive()
        guard case .data(let data) = message else {
            throw RelayClientError.unexpectedMessage
        }
        let envelope = try JSONDecoder().decode(RelayCiphertext.self, from: data)
        return try crypto.open(envelope, purpose: "transport")
    }

    public func disconnect() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func sendPing() async throws {
        guard let socket else { throw RelayClientError.invalidEndpoint }
        let gate = OneShotGate()
        let _: Void = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                guard gate.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

public struct RelayCatalogClient: Sendable {
    private let endpoint: URL
    private let address: RelayAddress
    private let crypto: RelayCrypto
    private let session: URLSession

    public init(endpoint: URL, rootKeyData: Data, session: URLSession = .shared) throws {
        self.endpoint = endpoint
        crypto = try RelayCrypto(rootKeyData: rootKeyData)
        address = crypto.address
        self.session = session
    }

    public func store(_ catalog: Data) async throws {
        try await store(catalog, replacing: nil)
    }

    public func update(_ transform: (Data?) throws -> Data?) async throws {
        for _ in 0..<8 {
            let snapshot = try await loadSnapshot()
            guard let catalog = try transform(snapshot.catalog) else { return }
            do {
                try await store(catalog, replacing: snapshot)
                return
            } catch RelayClientError.catalogChanged {
                continue
            }
        }
        throw RelayClientError.catalogChanged
    }

    private func store(_ catalog: Data, replacing snapshot: CatalogSnapshot?) async throws {
        var request = URLRequest(url: try catalogURL())
        request.httpMethod = "PUT"
        request.setValue("Bearer \(address.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag = snapshot?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        } else if snapshot?.catalog == nil, snapshot != nil {
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        request.httpBody = try JSONEncoder().encode(crypto.seal(catalog, purpose: "catalog"))
        let (_, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 412 {
            throw RelayClientError.catalogChanged
        }
        try validate(response, accepted: 204)
    }

    public func load() async throws -> Data? {
        try await loadSnapshot().catalog
    }

    private func loadSnapshot() async throws -> CatalogSnapshot {
        var request = URLRequest(url: try catalogURL())
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(address.credential)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RelayClientError.invalidResponse(-1)
        }
        if http.statusCode == 404 { return CatalogSnapshot(catalog: nil, etag: nil) }
        try validate(response, accepted: 200)
        let catalog = try crypto.open(
            JSONDecoder().decode(RelayCiphertext.self, from: data),
            purpose: "catalog"
        )
        return CatalogSnapshot(
            catalog: catalog,
            etag: http.value(forHTTPHeaderField: "ETag")
        )
    }

    private func catalogURL() throws -> URL {
        endpoint
            .appendingPathComponent("v1")
            .appendingPathComponent("catalog")
            .appendingPathComponent(address.room)
    }

    private func validate(_ response: URLResponse, accepted: Int) throws {
        guard let response = response as? HTTPURLResponse,
              response.statusCode == accepted else {
            throw RelayClientError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private struct CatalogSnapshot {
        var catalog: Data?
        var etag: String?
    }
}
