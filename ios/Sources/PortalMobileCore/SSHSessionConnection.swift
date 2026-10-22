import Foundation
import Citadel
import NIOCore
import NIOSSH

public actor SSHSessionConnection {
    private let host: SSHHost
    private let token: Data?
    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var stopped = false

    public init(host: SSHHost) { self.host = host; self.token = nil }

    init(host: SSHHost, token: Data) { self.host = host; self.token = token }

    private func connect() async throws -> SSHClient {
        try host.validate()
        let key = try SSHIdentity.privateKey(token: token ?? ICloudKeychainRootKey().loadOrCreate())
        var settings = SSHClientSettings(host: host.address, port: host.port,
            authenticationMethod: { .ed25519(username: self.host.username, privateKey: key) },
            hostKeyValidator: .trustedKeys([try NIOSSHPublicKey(openSSHPublicKey: host.hostPublicKey)]))
        settings.connectTimeout = .seconds(15)
        let connection = try await SSHClient.connect(to: settings)
        guard !stopped, !Task.isCancelled else {
            try? await connection.close()
            throw CancellationError()
        }
        client = connection
        return connection
    }

    func run(_ initial: SessionWireProtocol.ClientCommand,
             handle: @escaping @Sendable (SessionWireProtocol.ServerEvent) async throws -> Bool) async throws {
        let startupTimeout = Task {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { return }
            await self.close()
        }
        defer { startupTimeout.cancel() }
        let client = try await connect()
        do {
            try await withTaskCancellationHandler {
                let protocols = try await client.executeCommand(
                    "printf 'PROTOCOLS\\n' | " + SSHHost.quote(host.helperPath), maxResponseSize: 1024)
                guard case .supportedProtocols(let versions) = SessionWireProtocol.Decoder.decode(
                    String(decoding: protocols.readableBytesView, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                    versions.contains(SessionWireProtocol.currentVersion) else {
                    throw SSHSessionError.incompatibleProtocol
                }
                try await client.withExec(host.command) { inbound, outbound in
                    await self.setWriter(outbound)
                    try await outbound.write(.init(string: SessionWireProtocol.encode(initial) + "\n"))
                    var decoder = SessionWireProtocol.Decoder()
                    for try await output in inbound {
                        try Task.checkCancellation()
                        guard case .stdout(let buffer) = output else { continue }
                        // The helper wire format is ASCII with base64 payloads, so byte splits are safe.
                        for event in decoder.append(String(decoding: buffer.readableBytesView, as: UTF8.self)) {
                            startupTimeout.cancel()
                            if try await !handle(event) { return }
                        }
                    }
                    throw SSHSessionError.disconnected
                }
            } onCancel: {
                Task { await self.close() }
            }
            await close()
        } catch {
            await close()
            throw error
        }
    }

    private func setWriter(_ writer: TTYStdinWriter) { self.writer = writer }

    func send(_ command: SessionWireProtocol.ClientCommand) async throws {
        guard let writer, !stopped else { throw SSHSessionError.disconnected }
        try await writer.write(.init(string: SessionWireProtocol.encode(command) + "\n"))
    }

    public func close() async {
        stopped = true
        writer = nil
        let connection = client
        client = nil
        try? await connection?.close()
    }

    public func listSessions() async throws -> [RemoteCatalogSession] {
        let result = SessionResult()
        try await run(.list) { event in
            guard case .sessions(let data) = event else { throw SSHSessionError.invalidResponse }
            try await result.set(data)
            return false
        }
        return await result.sessions
    }

    public func createSession(peerID: String) async throws -> RemoteCatalogSession {
        let id = UUID().uuidString
        let session = RemoteCatalogSession(sessionID: id, title: "Terminal", cwd: host.homeDirectory,
            createdAt: Date(), commandCount: 0, runningCommand: nil, attachedClientCount: 0)
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            await self.close()
        }
        defer { timeout.cancel() }
        let marker = "\u{1b}]133;R;" + Data(host.homeDirectory.utf8).base64EncodedString() + "\u{7}"
        let ready = ShellReady(marker: marker)
        let bootstrap = PortalCommandEnvelope.inputSetupScript + "\nPROMPT=''; RPROMPT=''; PS1=''; printf "
            + SSHHost.quote(marker) + "\n"
        try await run(.attachV2(version: SessionWireProtocol.currentVersion, role: .phone,
            clientID: peerID, sessionID: id, workingDirectory: host.homeDirectory,
            shellPath: host.shellPath, environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "Portal", "PORTAL": "1"])) { event in
                switch event {
                case .ready(let created):
                    guard created else { throw SSHSessionError.invalidResponse }
                    try await self.send(.input(Data(bootstrap.utf8)))
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .secondsSince1970
                    try await self.send(.state(encoder.encode(RemoteSessionState(title: session.title,
                        cwd: session.cwd, createdAt: session.createdAt, commandCount: 0,
                        runningCommand: nil, commandHistory: []))))
                case .output(let text), .sequencedOutput(_, let text):
                    if await ready.consume(text) { return false }
                case .exit: throw SSHSessionError.disconnected
                default: break
                }
                return true
            }
        return session
    }

    func complete(operation: RemoteCompletionOperation, payload: Data) async throws -> Data {
        guard payload.count <= RemoteCompletionRequest.maximumPayloadSize else { throw SSHSessionError.invalidResponse }
        // A separate channel keeps completion output out of the terminal stream.
        let client = try await connect()
        do {
            let command = "printf %s " + SSHHost.quote(payload.base64EncodedString())
                + " | /usr/bin/base64 -d | " + SSHHost.quote(host.helperPath) + " " + operation.rawValue
            let buffer = try await client.executeCommand(command, maxResponseSize: RemoteCompletionResponse.maximumPayloadSize)
            await close()
            return Data(buffer.readableBytesView)
        } catch {
            await close()
            throw error
        }
    }
}

private actor SessionResult {
    var sessions: [RemoteCatalogSession] = []
    func set(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        sessions = try decoder.decode([SessionListing].self, from: data).map {
            RemoteCatalogSession(sessionID: $0.sessionId, title: $0.title, cwd: $0.cwd,
                createdAt: $0.createdAt, commandCount: $0.commandCount, lastCommandAt: $0.lastCommandAt,
                runningCommand: $0.runningCommand, attachedClientCount: $0.attachedClientCount ?? 0)
        }
    }
}

private struct SessionListing: Decodable {
    let sessionId: String
    let title: String
    let cwd: String
    let createdAt: Date
    let commandCount: Int
    let lastCommandAt: Date?
    let runningCommand: String?
    let attachedClientCount: Int?
}

private actor ShellReady {
    let marker: String
    var buffer = ""
    init(marker: String) { self.marker = marker }
    func consume(_ text: String) -> Bool {
        buffer += text
        if buffer.contains(marker) { return true }
        buffer = String(buffer.suffix(marker.count))
        return false
    }
}
