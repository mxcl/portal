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

public struct MobileCompletionSuggestion: Decodable, Identifiable, Sendable {
    public var id: String { "\(kind):\(displayText):\(insertText)" }
    public let displayText: String
    public let insertText: String
    public let description: String?
    public let kind: String
    public let priority: Int
    public let source: String
}

private struct MobileCompletionResponse: Decodable {
    let suggestions: [MobileCompletionSuggestion]
}

private struct MobileCommandCompletionRequest: Encodable {
    let prefix: String
}

private struct MobilePathCompletionRequest: Encodable {
    let cwd: String
    let prefix: String
    let foldersOnly: Bool
}

@MainActor
@Observable
public final class MobileRemoteModel {
    public private(set) var catalog: RemoteCatalog?
    public private(set) var connectionState: MobileConnectionState = .idle
    public private(set) var chunks: [TerminalChunk] = []
    public private(set) var terminalSize: RemoteTerminalSize?
    public private(set) var transcript = VaulttyBlockTranscript()
    public private(set) var presenceCount = 1
    public private(set) var isLocked = false
    public private(set) var creatingMacID: String?
    public private(set) var sessionCreationError: String?
    public private(set) var isRefreshingCatalog = false
    public private(set) var completionSuggestions: [MobileCompletionSuggestion] = []
    public private(set) var isCompleting = false
    public var showsPaywall = false

    private let endpoint: URL
    private let peerID: String
    private var client: RemoteTerminalSessionClient?
    private var receiveTask: Task<Void, Never>?
    private var nextChunkID: UInt64 = 1
    private var backgroundedAt: Date?
    private var lastAuthenticatedAt: Date?
    private var backgroundGraceTask: Task<Void, Never>?
    private var targetSession: RemoteCatalogSession?
    private var targetMac: RemoteMac?
    private var supportsCompletion = false
    private var commandCompletions: [MobileCompletionSuggestion] = []
    private var completionOperation: RemoteCompletionOperation?
    private var completionPrefix = ""
    private var completionIsCommand = true
    private var completionTask: Task<Void, Never>?
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
        resetCompletion()
        receiveTask?.cancel()
        receiveTask = nil
        if let client { Task { await client.disconnect() } }
        client = nil
        connectionState = .idle
        if clearTarget {
            targetSession = nil
            targetMac = nil
        }
    }

    public func sendInput(_ data: Data) {
        send(.input(data))
    }

    public func submit(_ command: String) {
        send(.submit(command))
    }

    public func interrupt() {
        send(.interrupt)
    }

    public func complete(_ input: String, cwd: String) {
        completionPrefix = input.lastIndex(where: \.isWhitespace)
            .map { String(input[input.index(after: $0)...]) } ?? input
        completionIsCommand = !input.contains(where: \.isWhitespace)
        completionSuggestions = []
        isCompleting = !input.isEmpty
        guard !input.isEmpty else {
            cancelRemoteCompletion()
            return
        }
        guard supportsCompletion else { return }

        if completionIsCommand {
            if !commandCompletions.isEmpty {
                cancelRemoteCompletion()
                showCommandCompletions()
            } else if completionOperation != .completeCommands {
                requestCompletion(
                    .completeCommands,
                    payload: MobileCommandCompletionRequest(prefix: "")
                )
            }
        } else {
            requestCompletion(
                .completePath,
                payload: MobilePathCompletionRequest(
                    cwd: cwd,
                    prefix: completionPrefix,
                    foldersOnly: false
                )
            )
        }
    }

    public func cancelCompletion() {
        cancelRemoteCompletion()
        completionSuggestions = []
        isCompleting = false
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
        resetCompletion()
        let key = try ICloudKeychainRootKey().loadOrCreate()
        let client = RemoteTerminalSessionClient(
            peerID: peerID,
            macID: mac.id,
            sessionID: session.sessionID,
            role: .phone,
            transport: try RelayClient(endpoint: endpoint, rootKeyData: key)
        )
        self.client = client
        chunks.removeAll(keepingCapacity: true)
        terminalSize = nil
        transcript.reset()
        try await client.run { [weak self] event in
            await self?.handle(event)
        }
    }

    private func handle(_ event: RemoteTerminalEvent) {
        switch event {
        case .connection(.connecting):
            connectionState = .connecting
        case .connection(.attached):
            connectionState = .attached
        case .connection(.reconnecting):
            connectionState = .reconnecting
        case .output(let data), .history(let data):
            appendChunk(data)
            if let text = String(data: data, encoding: .utf8) {
                transcript.consume(text)
            }
        case .snapshot(let snapshot):
            terminalSize = RemoteTerminalSize(rows: snapshot.rows, cols: snapshot.cols)
            appendChunk(snapshot.contents)
        case .size(let size):
            terminalSize = size
        case .presence(let count):
            presenceCount = count
        case .completionAvailabilityChanged(let available):
            supportsCompletion = available
            if supportsCompletion {
                if isCompleting {
                    completeCurrentInput(cwd: targetSession?.cwd ?? "/")
                } else {
                    requestCompletion(
                        .completeCommands,
                        payload: MobileCommandCompletionRequest(prefix: "")
                    )
                }
            } else {
                cancelRemoteCompletion()
            }
        }
    }

    private func appendChunk(_ data: Data) {
        chunks.append(TerminalChunk(id: nextChunkID, data: data))
        nextChunkID &+= 1
        if chunks.count > 2_000 {
            chunks.removeFirst(chunks.count - 2_000)
        }
    }

    private func completeCurrentInput(cwd: String) {
        if completionIsCommand {
            if commandCompletions.isEmpty {
                requestCompletion(
                    .completeCommands,
                    payload: MobileCommandCompletionRequest(prefix: "")
                )
            } else {
                showCommandCompletions()
            }
        } else {
            requestCompletion(
                .completePath,
                payload: MobilePathCompletionRequest(
                    cwd: cwd,
                    prefix: completionPrefix,
                    foldersOnly: false
                )
            )
        }
    }

    private func requestCompletion<T: Encodable>(
        _ operation: RemoteCompletionOperation,
        payload: T
    ) {
        guard supportsCompletion,
              let client,
              let input = try? JSONEncoder().encode(payload),
              input.count <= RemoteCompletionRequest.maximumPayloadSize
        else { return }
        cancelRemoteCompletion()
        completionOperation = operation
        completionTask = Task { [weak self] in
            do {
                let output = try await client.complete(
                    operation: operation,
                    payload: input,
                    timeout: 2
                )
                guard !Task.isCancelled else { return }
                self?.handleCompletionResponse(output, operation: operation)
            } catch is CancellationError {
                return
            } catch {
                self?.isCompleting = false
            }
        }
    }

    private func handleCompletionResponse(
        _ output: Data,
        operation: RemoteCompletionOperation
    ) {
        completionTask = nil
        completionOperation = nil
        guard let decoded = try? JSONDecoder().decode(
            MobileCompletionResponse.self,
            from: output
        )
        else {
            isCompleting = false
            return
        }
        if operation == .completeCommands {
            commandCompletions = decoded.suggestions
            if completionIsCommand, isCompleting {
                showCommandCompletions()
            }
        } else {
            completionSuggestions = Array(decoded.suggestions.prefix(8))
            isCompleting = false
        }
    }

    private func showCommandCompletions() {
        completionSuggestions = Array(commandCompletions
            .filter {
                completionPrefix.isEmpty ||
                    $0.displayText.range(
                        of: completionPrefix,
                        options: [.anchored, .caseInsensitive]
                    ) != nil
            }
            .sorted { $0.displayText.localizedStandardCompare($1.displayText) == .orderedAscending }
            .prefix(8))
        isCompleting = false
    }

    private func cancelRemoteCompletion() {
        completionTask?.cancel()
        completionTask = nil
        completionOperation = nil
    }

    private func resetCompletion() {
        cancelRemoteCompletion()
        supportsCompletion = false
        commandCompletions = []
        completionSuggestions = []
        isCompleting = false
    }

    private func send(_ command: RemoteTerminalCommand) {
        guard let client else { return }
        Task { try? await client.send(command) }
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
            localizedReason: "Attach to your Portal Terminal sessions"
        )
        lastAuthenticatedAt = Date()
    }
}
#endif
