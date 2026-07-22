#if os(iOS)
import Foundation
import LocalAuthentication
import Observation
import VaulttyCore

public enum MobileConnectionState: Equatable, Sendable {
    case idle
    case authenticating
    case connecting
    case attached
    case reconnecting
    case failed(String)
}

public struct TerminalChunk: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let data: Data
}

@MainActor
@Observable
public final class MobileRemoteModel {
    public private(set) var catalog: RemoteCatalog?
    public private(set) var connectionState: MobileConnectionState = .idle
    public private(set) var chunks: [TerminalChunk] = []
    public private(set) var transcript = VaulttyBlockTranscript()
    public private(set) var presenceCount = 1
    public private(set) var isLocked = false
    public private(set) var creatingMacID: String?
    public private(set) var sessionCreationError: String?
    public private(set) var isRefreshingCatalog = false
    public var showsPaywall = false

    private let endpoint: URL
    private let peerID: String
    private var relay: RelayClient?
    private var receiveTask: Task<Void, Never>?
    private var requestID: String?
    private var attachedMacID: String?
    private var attachedSessionID: String?
    private var sequenceTracker = RemoteSequenceTracker()
    private var nextChunkID: UInt64 = 1
    private var backgroundedAt: Date?
    private var lastAuthenticatedAt: Date?
    private var backgroundGraceTask: Task<Void, Never>?
    private var targetSession: RemoteCatalogSession?
    private var targetMac: RemoteMac?
    public init(endpoint: URL = URL(string: "https://vaultty-relay.mxcl.dev")!) {
        self.endpoint = endpoint
        if let existing = UserDefaults.standard.string(forKey: "vaulttyRemotePeerID") {
            peerID = existing
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: "vaulttyRemotePeerID")
            peerID = created
        }
    }

    public func refreshCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        do {
            let key = try ICloudKeychainRootKey().loadOrCreate()
            let client = try RelayCatalogClient(endpoint: endpoint, rootKeyData: key)
            guard let data = try await client.load() else {
                catalog = RemoteCatalog(generatedAt: Date(), macs: [])
                return
            }
            catalog = try JSONDecoder().decode(RemoteCatalog.self, from: data)
        } catch is CancellationError {
            return
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    public func attach(to session: RemoteCatalogSession, on mac: RemoteMac, store: MobileStore) {
        guard store.hasEntitlement else {
            showsPaywall = true
            return
        }
        targetSession = session
        targetMac = mac
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                connectionState = .authenticating
                try await authenticateIfNeeded()
                try await connect(session: session, mac: mac)
            } catch is CancellationError {
                connectionState = .idle
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    public func createSession(on mac: RemoteMac, store: MobileStore) async -> RemoteCatalogSession? {
        guard store.hasEntitlement else {
            showsPaywall = true
            return nil
        }
        guard creatingMacID == nil else { return nil }
        creatingMacID = mac.id
        sessionCreationError = nil
        defer { creatingMacID = nil }
        do {
            try await authenticateIfNeeded()
            let key = try ICloudKeychainRootKey().loadOrCreate()
            let endpoint = self.endpoint
            let client = RemoteSessionCreationClient {
                try RelayClient(endpoint: endpoint, rootKeyData: key)
            }
            let session = try await client.createSession(
                on: mac.id,
                sessionID: UUID().uuidString,
                peerID: peerID
            )
            catalog?.record(session, onMac: mac.id)
            return session
        } catch is CancellationError {
            return nil
        } catch {
            sessionCreationError = error.localizedDescription
            return nil
        }
    }

    public func dismissSessionCreationError() {
        sessionCreationError = nil
    }

    public func detach() {
        closeConnection(clearTarget: true)
    }

    private func closeConnection(clearTarget: Bool) {
        if let requestID, let attachedMacID, let attachedSessionID {
            send(RemoteMessage(
                kind: .detach,
                requestID: requestID,
                macID: attachedMacID,
                sessionID: attachedSessionID
            ))
        }
        receiveTask?.cancel()
        receiveTask = nil
        if let relay { Task { await relay.disconnect() } }
        relay = nil
        requestID = nil
        connectionState = .idle
        if clearTarget {
            targetSession = nil
            targetMac = nil
        }
    }

    public func sendInput(_ data: Data) {
        guard let requestID, let attachedMacID, let attachedSessionID else { return }
        send(RemoteMessage(
            kind: .input,
            requestID: requestID,
            macID: attachedMacID,
            sessionID: attachedSessionID,
            payload: data
        ))
    }

    public func submit(_ command: String) {
        guard let requestID, let attachedMacID, let attachedSessionID else { return }
        send(RemoteMessage(
            kind: .submit,
            requestID: requestID,
            macID: attachedMacID,
            sessionID: attachedSessionID,
            payload: Data(command.utf8)
        ))
    }

    public func interrupt() {
        guard let requestID, let attachedMacID, let attachedSessionID else { return }
        send(RemoteMessage(
            kind: .interrupt,
            requestID: requestID,
            macID: attachedMacID,
            sessionID: attachedSessionID
        ))
    }

    public func sceneDidEnterBackground() {
        backgroundedAt = Date()
        backgroundGraceTask?.cancel()
        backgroundGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, self?.backgroundedAt != nil else { return }
            self?.closeConnection(clearTarget: false)
        }
    }

    public func sceneDidBecomeActive() {
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        if backgroundedAt.map({ Date().timeIntervalSince($0) >= 300 }) == true {
            isLocked = true
            closeConnection(clearTarget: false)
        } else if connectionState == .idle,
                  let targetSession,
                  let targetMac {
            receiveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await authenticateIfNeeded()
                    try await connect(session: targetSession, mac: targetMac)
                } catch is CancellationError {
                    connectionState = .idle
                } catch {
                    connectionState = .failed(error.localizedDescription)
                }
            }
        }
        backgroundedAt = nil
    }

    public func unlock() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await authenticateIfNeeded(force: true)
                isLocked = false
                if let targetSession, let targetMac {
                    try await connect(session: targetSession, mac: targetMac)
                }
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }

    private func connect(session: RemoteCatalogSession, mac: RemoteMac) async throws {
        let key = try ICloudKeychainRootKey().loadOrCreate()
        let relay = try RelayClient(endpoint: endpoint, rootKeyData: key)
        self.relay = relay
        try await relay.connect(peerID: peerID)
        connectionState = .connecting
        chunks.removeAll(keepingCapacity: true)
        transcript.reset()
        sequenceTracker.reset(to: nil)
        let requestID = UUID().uuidString
        self.requestID = requestID
        attachedMacID = mac.id
        attachedSessionID = session.sessionID
        try await relay.send(JSONEncoder().encode(RemoteMessage(
            kind: .attach,
            requestID: requestID,
            macID: mac.id,
            sessionID: session.sessionID
        )))
        connectionState = .attached

        var retryDelay = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                let data = try await relay.receive()
                let message = try JSONDecoder().decode(RemoteMessage.self, from: data)
                try handle(message)
                retryDelay = .seconds(1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                connectionState = .reconnecting
                await relay.disconnect()
                try await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(30))
                try await relay.connect(peerID: peerID)
                sequenceTracker.reset(to: nil)
                try await relay.send(JSONEncoder().encode(RemoteMessage(
                    kind: .attach,
                    requestID: requestID,
                    macID: mac.id,
                    sessionID: session.sessionID
                )))
                connectionState = .attached
            }
        }
    }

    private func handle(_ message: RemoteMessage) throws {
        guard message.version == RemoteMessage.currentVersion,
              message.requestID == requestID,
              message.macID == attachedMacID else { return }
        switch message.kind {
        case .terminalEvent:
            guard let sequence = message.sequence,
                  sequenceTracker.accept(sequence) == .accepted,
                  let payload = message.payload else { return }
            chunks.append(TerminalChunk(id: nextChunkID, data: payload))
            if let text = String(data: payload, encoding: .utf8) {
                transcript.consume(text)
            }
            nextChunkID &+= 1
            if chunks.count > 2_000 {
                chunks.removeFirst(chunks.count - 2_000)
            }
        case .error:
            let text = message.payload.flatMap { String(data: $0, encoding: .utf8) } ?? "Remote session failed"
            connectionState = .failed(text)
        case .presence:
            if let payload = message.payload,
               let text = String(data: payload, encoding: .utf8),
               let count = Int(text) {
                presenceCount = count
            }
        case .catalog, .attach, .detach, .createSession, .sessionCreated,
             .input, .submit, .interrupt, .historyPage, .unknown:
            break
        }
    }

    private func send(_ message: RemoteMessage) {
        guard let relay, let data = try? JSONEncoder().encode(message) else { return }
        Task { try? await relay.send(data) }
    }

    private func authenticateIfNeeded(force: Bool = false) async throws {
        if !force,
           let lastAuthenticatedAt,
           Date().timeIntervalSince(lastAuthenticatedAt) < 300,
           !isLocked { return }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "Attach to your InfiniTerm sessions"
        )
        lastAuthenticatedAt = Date()
    }
}
#endif
