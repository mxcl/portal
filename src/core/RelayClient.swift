import Foundation

enum RelayClientError: Error, Equatable {
    case invalidEndpoint
    case unexpectedMessage
    case invalidResponse(Int)
}

actor RelayClient {
    private let endpoint: URL
    private let address: RelayAddress
    private let crypto: RelayCrypto
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?

    init(endpoint: URL, rootKeyData: Data, session: URLSession = .shared) throws {
        self.endpoint = endpoint
        crypto = try RelayCrypto(rootKeyData: rootKeyData)
        address = crypto.address
        self.session = session
    }

    func connect(peerID: String) throws {
        guard socket == nil else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.scheme = endpoint.scheme == "http" ? "ws" : "wss"
        components?.path = endpoint.path + "/v1/connect/\(address.room)/\(peerID)"
        guard let url = components?.url else {
            throw RelayClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(address.credential)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
    }

    func send(_ plaintext: Data) async throws {
        guard let socket else { throw RelayClientError.invalidEndpoint }
        let envelope = try crypto.seal(plaintext, purpose: "transport")
        try await socket.send(.data(JSONEncoder().encode(envelope)))
    }

    func receive() async throws -> Data {
        guard let socket else { throw RelayClientError.invalidEndpoint }
        let message = try await socket.receive()
        guard case .data(let data) = message else {
            throw RelayClientError.unexpectedMessage
        }
        let envelope = try JSONDecoder().decode(RelayCiphertext.self, from: data)
        return try crypto.open(envelope, purpose: "transport")
    }

    func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }
}

struct RelayCatalogClient: Sendable {
    private let endpoint: URL
    private let address: RelayAddress
    private let crypto: RelayCrypto
    private let session: URLSession

    init(endpoint: URL, rootKeyData: Data, session: URLSession = .shared) throws {
        self.endpoint = endpoint
        crypto = try RelayCrypto(rootKeyData: rootKeyData)
        address = crypto.address
        self.session = session
    }

    func store(_ catalog: Data) async throws {
        var request = URLRequest(url: try catalogURL())
        request.httpMethod = "PUT"
        request.setValue("Bearer \(address.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(crypto.seal(catalog, purpose: "catalog"))
        let (_, response) = try await session.data(for: request)
        try validate(response, accepted: 204)
    }

    func load() async throws -> Data? {
        var request = URLRequest(url: try catalogURL())
        request.setValue("Bearer \(address.credential)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RelayClientError.invalidResponse(-1)
        }
        if http.statusCode == 404 { return nil }
        try validate(response, accepted: 200)
        return try crypto.open(
            JSONDecoder().decode(RelayCiphertext.self, from: data),
            purpose: "catalog"
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
}
