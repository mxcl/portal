import Foundation
import OSLog

private let remoteAccessLogger = Logger(
    subsystem: "com.automicvault.vaultty",
    category: "RemoteAccess"
)

private final class RemoteCompletionProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func run(
        helper: URL,
        operation: RemoteCompletionOperation,
        input: Data
    ) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try self.runSync(helper: helper, operation: operation, input: input)
                    })
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let process = process
        lock.unlock()
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func runSync(
        helper: URL,
        operation: RemoteCompletionOperation,
        input: Data
    ) throws -> Data {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helper
        process.arguments = [operation.rawValue]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        lock.lock()
        self.process = process
        lock.unlock()
        defer {
            lock.lock()
            self.process = nil
            lock.unlock()
        }

        try Task.checkCancellation()
        try process.run()
        inputPipe.fileHandleForWriting.write(input)
        try inputPipe.fileHandleForWriting.close()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(data: error, encoding: .utf8) ?? "Completion helper failed"
                ]
            )
        }
        return output
    }
}

@MainActor
final class MacRemoteAccessController {
    static let enabledDefaultsKey = "remoteAccessEnabled"
    static let endpointDefaultsKey = "remoteAccessRelayEndpoint"
    static let macIDDefaultsKey = "remoteAccessMacID"

    private struct Bridge {
        var session: PtySession
        var nextSequence: UInt64
        var sessionID: String
    }

    private struct ActiveCompletion {
        var operationID: String
        var task: Task<Void, Never>
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
    private var activeCompletions: [String: ActiveCompletion] = [:]

    init() {
        macID = Self.macID()
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
                    try? await catalog?.update { self.catalogData(merging: $0) }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        } catch {
            stop()
            NSLog("Portal remote access could not start: \(error)")
        }
    }

    private func launchAgent() {
        guard agentProcess?.isRunning != true else { return }
        guard let helper = remoteAgentURL() else {
            remoteAccessLogger.error("Portal remote agent is missing")
            return
        }
        let endpoint: URL
        do {
            endpoint = try relayEndpoint()
        } catch {
            remoteAccessLogger.error(
                "Portal remote relay endpoint is invalid: \(String(describing: error), privacy: .public)"
            )
            return
        }
        let key: Data
        do {
            key = try ICloudKeychainRootKey().loadOrCreate()
        } catch {
            remoteAccessLogger.error(
                "Portal remote key is unavailable: \(String(describing: error), privacy: .public)"
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
                "Portal remote agent exited with status \(process.terminationStatus)"
            )
        }
        do {
            try process.run()
            agentProcess = process
            keyPipe.fileHandleForWriting.write(key)
            try? keyPipe.fileHandleForWriting.close()
        } catch {
            remoteAccessLogger.error(
                "Portal remote agent could not launch: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func terminateAgent() {
        agentProcess?.terminationHandler = nil
        for name in ["portal-remote-agent", "vaultty-remote-agent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            process.arguments = ["-TERM", "-x", name]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                remoteAccessLogger.error(
                    "Portal remote agent could not be terminated: \(String(describing: error), privacy: .public)"
                )
            }
        }
        agentProcess = nil
    }

    private func remoteAgentURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/portal-remote-agent")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let local = URL(fileURLWithPath: "target/debug/portal-remote-agent")
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
        activeCompletions.values.forEach { $0.task.cancel() }
        activeCompletions.removeAll()
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
        case .resize:
            guard let payload = message.payload,
                  let size = try? JSONDecoder().decode(RemoteTerminalSize.self, from: payload)
            else { return }
            bridges[message.requestID]?.session.resize(rows: size.rows, cols: size.cols)
        case .clearHistory:
            bridges[message.requestID]?.session.clearHistory()
        case .updateState:
            guard let payload = message.payload,
                  let state = try? JSONDecoder().decode(RemoteSessionState.self, from: payload)
            else { return }
            bridges[message.requestID]?.session.updateState(
                title: state.title,
                cwd: state.cwd,
                createdAt: state.createdAt,
                commandCount: state.commandCount,
                runningCommand: state.runningCommand,
                commandHistory: state.commandHistory
            )
        case .kill:
            bridges.removeValue(forKey: message.requestID)?.session.kill()
        case .completionRequest:
            startCompletion(message)
        case .completionCancel:
            cancelCompletion(message)
        case .historyPage:
            break
        case .catalog, .sessionCreated, .terminalEvent, .presence, .capabilities,
             .completionResponse, .error, .unknown:
            break
        }
    }

    private func startCompletion(_ message: RemoteMessage) {
        guard let bridge = bridges[message.requestID],
              bridge.sessionID == message.sessionID,
              let payload = message.payload,
              payload.count <= RemoteCompletionRequest.maximumPayloadSize,
              let request = try? JSONDecoder().decode(
                RemoteCompletionRequest.self,
                from: payload
              ),
              request.payload.count <= RemoteCompletionRequest.maximumPayloadSize,
              let helper = completionBridgeURL()
        else {
            return
        }

        activeCompletions.removeValue(forKey: message.requestID)?.task.cancel()
        let process = RemoteCompletionProcess()
        let task = Task { [weak self] in
            let response: RemoteCompletionResponse?
            do {
                let output = try await process.run(
                    helper: helper,
                    operation: request.operation,
                    input: request.payload
                )
                try Task.checkCancellation()
                guard output.count <= RemoteCompletionResponse.maximumPayloadSize else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(EFBIG),
                        userInfo: [
                            NSLocalizedDescriptionKey: "Completion response is too large"
                        ]
                    )
                }
                response = RemoteCompletionResponse(
                    operationID: request.operationID,
                    payload: output
                )
            } catch is CancellationError {
                response = nil
            } catch {
                response = RemoteCompletionResponse(
                    operationID: request.operationID,
                    error: error.localizedDescription
                )
            }
            self?.finishCompletion(
                response,
                requestID: message.requestID,
                sessionID: bridge.sessionID,
                operationID: request.operationID
            )
        }
        activeCompletions[message.requestID] = ActiveCompletion(
            operationID: request.operationID,
            task: task
        )
    }

    private func cancelCompletion(_ message: RemoteMessage) {
        guard let payload = message.payload,
              let cancellation = try? JSONDecoder().decode(
                RemoteCompletionCancellation.self,
                from: payload
              ),
              activeCompletions[message.requestID]?.operationID == cancellation.operationID
        else {
            return
        }
        activeCompletions.removeValue(forKey: message.requestID)?.task.cancel()
    }

    private func finishCompletion(
        _ response: RemoteCompletionResponse?,
        requestID: String,
        sessionID: String,
        operationID: String
    ) {
        guard activeCompletions[requestID]?.operationID == operationID else { return }
        activeCompletions.removeValue(forKey: requestID)
        guard let response,
              let payload = try? JSONEncoder().encode(response) else { return }
        send(RemoteMessage(
            kind: .completionResponse,
            requestID: requestID,
            macID: macID,
            sessionID: sessionID,
            payload: payload
        ))
    }

    private func completionBridgeURL() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/portal-session-bridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let local = URL(fileURLWithPath: "target/debug/portal-session-bridge")
        return FileManager.default.isExecutableFile(atPath: local.path) ? local : nil
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
        environment["TERM_PROGRAM"] = "Portal"
        environment["LC_TERMINAL"] = "Portal"
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
        export TERM_PROGRAM=Portal
        export LC_TERMINAL=Portal
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
        if let payload = try? JSONEncoder().encode(RemoteCapabilities(
            values: [RemoteCapabilities.relayCompletion]
        )) {
            send(RemoteMessage(
                kind: .capabilities,
                requestID: message.requestID,
                macID: macID,
                sessionID: sessionID,
                payload: payload
            ))
        }
        session.onHistoryOutput = { [weak self] text in
            DispatchQueue.main.async {
                self?.sendTerminal(text, requestID: message.requestID, isHistory: true)
            }
        }
        session.onOutput = { [weak self] text in
            DispatchQueue.main.async {
                self?.sendTerminal(text, requestID: message.requestID, isHistory: false)
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
        let role: SessionWireProtocol.ClientRole = message.clientRole == .mac ? .mac : .phone
        session.joinExisting(role: role) { [weak self] result in
            if case .failure(let error) = result {
                self?.sendError(error.localizedDescription, request: message)
                self?.detach(requestID: message.requestID)
            }
        }
    }

    private func detach(requestID: String) {
        activeCompletions.removeValue(forKey: requestID)?.task.cancel()
        bridges.removeValue(forKey: requestID)?.session.stop()
    }

    private func sendTerminal(_ text: String, requestID: String, isHistory: Bool) {
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
            payload: Data(text.utf8),
            isHistory: isHistory
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
                "Portal session listing failed: \(String(describing: error), privacy: .public)"
            )
            sessions = []
        }
        let now = Date()
        let mac = RemoteMac(
            id: macID,
            name: Host.current().localizedName ?? "Mac",
            online: true,
            lastSeen: now,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
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
            }
        )
        var existing = existingData.flatMap { try? JSONDecoder().decode(RemoteCatalog.self, from: $0) }
            ?? RemoteCatalog(generatedAt: now, macs: [])
        existing.generatedAt = now
        existing.macs.removeAll { $0.id == macID || now.timeIntervalSince($0.lastSeen) > 30 * 24 * 60 * 60 }
        existing.macs.append(mac)
        return try? JSONEncoder().encode(existing)
    }

    static func macID() -> String {
        if let existing = UserDefaults.standard.string(forKey: macIDDefaultsKey) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: macIDDefaultsKey)
        return created
    }

    static func relayEndpoint(configuredEndpoint: URL? = nil) throws -> URL {
        if let configuredEndpoint { return configuredEndpoint }
        let value = ProcessInfo.processInfo.environment["VAULTTY_RELAY_ENDPOINT"]
            ?? UserDefaults.standard.string(forKey: endpointDefaultsKey)
            ?? "https://vaultty-relay.mxcl.dev"
        guard let endpoint = URL(string: value),
              endpoint.scheme == "https" || endpoint.scheme == "http" else {
            throw RelayClientError.invalidEndpoint
        }
        return endpoint
    }

    private func relayEndpoint() throws -> URL {
        try Self.relayEndpoint(configuredEndpoint: configuredEndpoint)
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}
