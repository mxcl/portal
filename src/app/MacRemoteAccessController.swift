import Foundation
import OSLog

private let remoteAccessLogger = Logger(
    subsystem: "com.automicvault.vaultty",
    category: "RemoteAccess"
)

@MainActor
final class MacRemoteAccessController {
    static let enabledDefaultsKey = "remoteAccessEnabled"
    static let endpointDefaultsKey = "remoteAccessRelayEndpoint"

    private struct Bridge {
        var session: PtySession
        var nextSequence: UInt64
        var sessionID: String
    }

    private let macID: String
    private let configuredEndpoint: URL?
    private let suppliedRootKey: Data?
    private var relay: RelayClient?
    private var receiveTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var agentProcess: Process?
    private var bridges: [String: Bridge] = [:]
    private var pendingCreations: [String: PtySession] = [:]

    init() {
        if let existing = UserDefaults.standard.string(forKey: "remoteAccessMacID") {
            macID = existing
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: "remoteAccessMacID")
            macID = created
        }
        configuredEndpoint = nil
        suppliedRootKey = nil
    }

    init(agentMacID: String, endpoint: URL, rootKey: Data) {
        macID = agentMacID
        configuredEndpoint = endpoint
        suppliedRootKey = rootKey
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        launchAgent()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        enabled ? launchAgent() : terminateAgent()
    }

    func startAgentConnection() {
        guard receiveTask == nil else { return }
        do {
            let key = try suppliedRootKey ?? ICloudKeychainRootKey().loadOrCreate()
            let endpoint = try relayEndpoint()
            let relay = try RelayClient(endpoint: endpoint, rootKeyData: key)
            self.relay = relay
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(relay: relay)
            }
            catalogTask = Task { [weak self] in
                guard let self else { return }
                let catalog = try? RelayCatalogClient(endpoint: endpoint, rootKeyData: key)
                while !Task.isCancelled {
                    let existingData = try? await catalog?.load()
                    if let data = self.catalogData(merging: existingData ?? nil) {
                        try? await catalog?.store(data)
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch {
            stop()
            NSLog("Vaultty remote access could not start: \(error)")
        }
    }

    private func launchAgent() {
        guard agentProcess?.isRunning != true else { return }
        guard let helper = remoteAgentURL() else {
            remoteAccessLogger.error("Vaultty remote agent is missing")
            return
        }
        let endpoint: URL
        do {
            endpoint = try relayEndpoint()
        } catch {
            remoteAccessLogger.error(
                "Vaultty remote relay endpoint is invalid: \(String(describing: error), privacy: .public)"
            )
            return
        }
        let key: Data
        do {
            key = try ICloudKeychainRootKey().loadOrCreate()
        } catch {
            remoteAccessLogger.error(
                "Vaultty remote key is unavailable: \(String(describing: error), privacy: .public)"
            )
            return
        }
        // App updates replace the helper on disk but do not terminate its running
        // process. Retire that old image before advertising with the bundled build.
        terminateAgent()
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--mac-id", macID, "--endpoint", endpoint.absoluteString]
        let keyPipe = Pipe()
        process.standardInput = keyPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            remoteAccessLogger.error(
                "Vaultty remote agent exited with status \(process.terminationStatus)"
            )
        }
        do {
            try process.run()
            agentProcess = process
            keyPipe.fileHandleForWriting.write(key)
            try? keyPipe.fileHandleForWriting.close()
        } catch {
            remoteAccessLogger.error(
                "Vaultty remote agent could not launch: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func terminateAgent() {
        agentProcess?.terminationHandler = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-TERM", "-x", "vaultty-remote-agent"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            remoteAccessLogger.error(
                "Vaultty remote agent could not be terminated: \(String(describing: error), privacy: .public)"
            )
        }
        agentProcess = nil
    }

    private func remoteAgentURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/vaultty-remote-agent")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let local = URL(fileURLWithPath: "target/debug/vaultty-remote-agent")
        return FileManager.default.isExecutableFile(atPath: local.path) ? local : nil
    }

    private func stop() {
        receiveTask?.cancel()
        catalogTask?.cancel()
        receiveTask = nil
        catalogTask = nil
        bridges.values.forEach { $0.session.stop() }
        bridges.removeAll()
        pendingCreations.values.forEach { $0.stop() }
        pendingCreations.removeAll()
        if let relay {
            Task { await relay.disconnect() }
        }
        relay = nil
    }

    private func receiveLoop(relay: RelayClient) async {
        var retryDelay = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                try await relay.connect(peerID: macID)
                retryDelay = .seconds(1)
                while !Task.isCancelled {
                    let data = try await relay.receive()
                    let message = try JSONDecoder().decode(RemoteMessage.self, from: data)
                    handle(message)
                }
            } catch is CancellationError {
                break
            } catch {
                await relay.disconnect()
                try? await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(30))
            }
        }
    }

    private func handle(_ message: RemoteMessage) {
        guard message.version == RemoteMessage.currentVersion,
              message.macID == nil || message.macID == macID else { return }
        switch message.kind {
        case .attach:
            attach(message)
        case .detach:
            detach(requestID: message.requestID)
        case .createSession:
            createSession(message)
        case .input:
            if let payload = message.payload,
               let text = String(data: payload, encoding: .utf8) {
                bridges[message.requestID]?.session.write(text)
            }
        case .submit:
            if let payload = message.payload,
               let command = String(data: payload, encoding: .utf8) {
                bridges[message.requestID]?.session.write(
                    VaulttyCommandEnvelope.shellScript(for: command)
                )
            }
        case .interrupt:
            bridges[message.requestID]?.session.sendInterrupt()
        case .historyPage:
            break
        case .catalog, .sessionCreated, .terminalEvent, .presence, .error:
            break
        }
    }

    private func createSession(_ message: RemoteMessage) {
        guard let sessionID = message.sessionID,
              !sessionID.isEmpty,
              pendingCreations[message.requestID] == nil else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["TERM_PROGRAM"] = "Vaultty"
        environment["LC_TERMINAL"] = "Vaultty"
        environment["VAULTTY"] = "1"
        environment["PROMPT"] = ""
        environment["RPROMPT"] = ""

        let session = PtySession(sessionID: sessionID)
        pendingCreations[message.requestID] = session
        session.onReady = { [weak self, weak session] created in
            guard let self, let session,
                  self.pendingCreations[message.requestID] === session else { return }

            let metadata: RemoteCatalogSession
            if created {
                session.write(self.shellBootstrap(home: home), suppressEcho: true)
                let createdAt = Date()
                session.updateState(
                    title: "~",
                    cwd: home.path,
                    createdAt: createdAt,
                    commandCount: 0,
                    runningCommand: nil,
                    commandHistory: []
                )
                metadata = RemoteCatalogSession(
                    sessionID: sessionID,
                    title: "~",
                    cwd: home.path,
                    createdAt: createdAt,
                    commandCount: 0,
                    runningCommand: nil,
                    attachedClientCount: 0
                )
            } else if let existing = try? PtySession.listSessions().first(where: {
                $0.sessionID == sessionID
            }) {
                metadata = RemoteCatalogSession(
                    sessionID: existing.sessionID,
                    title: existing.title,
                    cwd: existing.cwd,
                    createdAt: existing.createdAt,
                    commandCount: existing.commandCount,
                    runningCommand: existing.runningCommand,
                    attachedClientCount: existing.attachedClientCount
                )
            } else {
                self.failCreation("The new session could not be found.", request: message)
                return
            }

            guard let payload = try? JSONEncoder().encode(metadata) else {
                self.failCreation("The new session could not be encoded.", request: message)
                return
            }
            self.send(RemoteMessage(
                kind: .sessionCreated,
                requestID: message.requestID,
                macID: self.macID,
                sessionID: sessionID,
                payload: payload
            ))
            self.pendingCreations.removeValue(forKey: message.requestID)
            session.stop()
        }
        session.onExit = { [weak self, weak session] _ in
            guard let self, let session,
                  self.pendingCreations[message.requestID] === session else { return }
            self.failCreation("The Mac could not start its login shell.", request: message)
        }
        session.start(
            shellPath: shell,
            environment: environment,
            workingDirectory: home
        ) { [weak self, weak session] result in
            guard case .failure(let error) = result,
                  let self, let session,
                  self.pendingCreations[message.requestID] === session else { return }
            self.failCreation(error.localizedDescription, request: message)
        }
    }

    private func failCreation(_ text: String, request: RemoteMessage) {
        let session = pendingCreations.removeValue(forKey: request.requestID)
        sendError(text, request: request)
        session?.stop()
    }

    private func shellBootstrap(home: URL) -> String {
        """
        export VAULTTY=1
        export TERM=xterm-256color
        export TERM_PROGRAM=Vaultty
        export LC_TERMINAL=Vaultty
        cd \(shellQuote(home.path))
        stty -echo
        PROMPT=''
        RPROMPT=''
        setopt no_prompt_cr 2>/dev/null || true
        printf '\\033]133;R;%s\\a' "$(pwd | base64)"

        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func attach(_ message: RemoteMessage) {
        guard let sessionID = message.sessionID else { return }
        detach(requestID: message.requestID)
        let session = PtySession(sessionID: sessionID)
        bridges[message.requestID] = Bridge(
            session: session,
            nextSequence: 1,
            sessionID: sessionID
        )
        session.onHistoryOutput = { [weak self] text in
            DispatchQueue.main.async {
                self?.sendTerminal(text, requestID: message.requestID)
            }
        }
        session.onOutput = { [weak self] text in
            DispatchQueue.main.async {
                self?.sendTerminal(text, requestID: message.requestID)
            }
        }
        session.onExit = { [weak self] status in
            DispatchQueue.main.async {
                self?.sendError("Session ended (\(status))", request: message)
                self?.detach(requestID: message.requestID)
            }
        }
        session.onPresence = { [weak self] count in
            DispatchQueue.main.async {
                self?.send(RemoteMessage(
                    kind: .presence,
                    requestID: message.requestID,
                    macID: self?.macID,
                    sessionID: sessionID,
                    payload: Data(String(count).utf8)
                ))
            }
        }
        session.joinExisting { [weak self] result in
            if case .failure(let error) = result {
                self?.sendError(error.localizedDescription, request: message)
                self?.detach(requestID: message.requestID)
            }
        }
    }

    private func detach(requestID: String) {
        bridges.removeValue(forKey: requestID)?.session.stop()
    }

    private func sendTerminal(_ text: String, requestID: String) {
        guard var bridge = bridges[requestID] else { return }
        let sequence = bridge.nextSequence
        bridge.nextSequence = bridge.nextSequence.saturatingAdding(1)
        bridges[requestID] = bridge
        send(RemoteMessage(
            kind: .terminalEvent,
            requestID: requestID,
            macID: macID,
            sessionID: bridge.sessionID,
            sequence: sequence,
            payload: Data(text.utf8)
        ))
    }

    private func sendError(_ text: String, request: RemoteMessage) {
        send(RemoteMessage(
            kind: .error,
            requestID: request.requestID,
            macID: macID,
            sessionID: request.sessionID,
            payload: Data(text.utf8)
        ))
    }

    private func send(_ message: RemoteMessage) {
        guard let relay, let data = try? JSONEncoder().encode(message) else { return }
        Task {
            try? await relay.send(data)
        }
    }

    private func catalogData(merging existingData: Data?) -> Data? {
        let sessions: [SessionMetadata]
        do {
            sessions = try PtySession.listSessions()
        } catch {
            remoteAccessLogger.error(
                "Vaultty session listing failed: \(String(describing: error), privacy: .public)"
            )
            sessions = []
        }
        let now = Date()
        let mac = RemoteMac(
            id: macID,
            name: Host.current().localizedName ?? "Mac",
            online: true,
            lastSeen: now,
            sessions: sessions.map {
                RemoteCatalogSession(
                    sessionID: $0.sessionID,
                    title: $0.title,
                    cwd: $0.cwd,
                    createdAt: $0.createdAt,
                    commandCount: $0.commandCount,
                    runningCommand: $0.runningCommand,
                    attachedClientCount: $0.attachedClientCount
                )
            },
            capabilities: [RemoteMac.createSessionCapability]
        )
        var existing = existingData.flatMap { try? JSONDecoder().decode(RemoteCatalog.self, from: $0) }
            ?? RemoteCatalog(generatedAt: now, macs: [])
        existing.generatedAt = now
        existing.macs.removeAll { $0.id == macID || now.timeIntervalSince($0.lastSeen) > 30 * 24 * 60 * 60 }
        existing.macs.append(mac)
        return try? JSONEncoder().encode(existing)
    }

    private func relayEndpoint() throws -> URL {
        if let configuredEndpoint { return configuredEndpoint }
        let value = ProcessInfo.processInfo.environment["VAULTTY_RELAY_ENDPOINT"]
            ?? UserDefaults.standard.string(forKey: Self.endpointDefaultsKey)
            ?? "https://vaultty-relay.mxcl.dev"
        guard let endpoint = URL(string: value),
              endpoint.scheme == "https" || endpoint.scheme == "http" else {
            throw RelayClientError.invalidEndpoint
        }
        return endpoint
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}
