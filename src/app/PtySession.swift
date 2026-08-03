import Foundation
import Darwin

@MainActor
protocol TerminalSession: AnyObject {
    var onOutput: ((String) -> Void)? { get set }
    var onHistoryOutput: ((String) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var onReady: ((Bool) -> Void)? { get set }
    var onPresence: ((Int) -> Void)? { get set }

    func start(
        shellPath: String,
        environment: [String: String],
        workingDirectory: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func resize(rows: UInt16, cols: UInt16)
    func isCanonicalInputModeEnabled() -> Bool?
    func sendInterrupt()
    func clearHistory()
    func write(_ string: String, suppressEcho: Bool)
    func updateState(
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        runningCommand: String?,
        commandHistory: [String]
    )
    func stop()
    func kill()
}

extension TerminalSession {
    func write(_ string: String) {
        write(string, suppressEcho: false)
    }
}

private protocol SessionTransport: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    var onDiagnostic: ((String) -> Void)? { get set }

    func start() throws
    func send(_ line: String) throws
    func close(terminate: Bool)
}

private final class LocalSessionTransport: SessionTransport {
    var onText: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private let queue: DispatchQueue
    private let connect: () throws -> Int32
    private let write: (String, Int32) throws -> Void
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?

    init(
        queue: DispatchQueue,
        connect: @escaping () throws -> Int32,
        write: @escaping (String, Int32) throws -> Void
    ) {
        self.queue = queue
        self.connect = connect
        self.write = write
    }

    func start() throws {
        let fd = try connect()
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                self.onExit?(0)
                return
            }
            self.onText?(String(decoding: buffer[0..<count], as: UTF8.self))
        }
        source.resume()
        readSource = source
    }

    func send(_ line: String) throws {
        guard fd >= 0 else { return }
        try write(line + "\n", fd)
    }

    func close(terminate: Bool) {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }
}

private final class SSHSessionTransport: SessionTransport {
    var onText: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    private let queue: DispatchQueue
    private let process: Process
    private let write: (String, Int32) throws -> Void
    private var input: FileHandle?
    private var output: FileHandle?
    private var error: FileHandle?
    private var errorOutput = Data()

    init(
        queue: DispatchQueue,
        process: Process,
        write: @escaping (String, Int32) throws -> Void
    ) {
        self.queue = queue
        self.process = process
        self.write = write
    }

    func start() throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        error = errorPipe.fileHandleForReading

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.onText?(String(decoding: data, as: UTF8.self))
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async {
                self?.errorOutput.append(data)
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.queue.async {
                guard let self else { return }
                let message = String(data: self.errorOutput, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus != 0, !message.isEmpty {
                    self.onDiagnostic?("\nSSH bridge failed: \(message)\n")
                }
                self.onExit?(process.terminationStatus)
            }
        }
    }

    func send(_ line: String) throws {
        guard let input else { return }
        try write(line + "\n", input.fileDescriptor)
    }

    func close(terminate: Bool) {
        output?.readabilityHandler = nil
        error?.readabilityHandler = nil
        try? input?.close()
        try? output?.close()
        try? error?.close()
        input = nil
        output = nil
        error = nil
        errorOutput.removeAll(keepingCapacity: false)
        if terminate, process.isRunning {
            process.terminate()
        }
        process.terminationHandler = nil
    }
}

final class PtySession {
    var onOutput: ((String) -> Void)?
    var onHistoryOutput: ((String) -> Void)?
    var onSnapshot: ((UInt16, UInt16, String) -> Void)?
    var onGeometry: ((UInt16, UInt16) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPresence: ((Int) -> Void)?

    private let sessionRef: SessionRef
    private var daemonIdentity: SessionDaemonIdentity {
        SessionDaemonIdentity(externalSessionID: sessionRef.sessionID)
    }
    private var wireSessionID: String {
        if case .local = sessionRef.location {
            return daemonIdentity.rawSessionID
        }
        return sessionRef.sessionID
    }
    private let clientID = UUID().uuidString
    private let queue = DispatchQueue(label: "com.automicvault.vaultty.session-client")
    private var transport: (any SessionTransport)?
    private var protocolDecoder = SessionWireProtocol.Decoder()
    private var treatsNextOutputAsLegacyHistory = false
    private let lifecycleLock = NSLock()
    private var isStopped = false
    private var didReportExit = false
    private static let daemonStartupLock = NSLock()
    private static let ignoreSIGPIPEOnce: Void = {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
    }()

    init(sessionID: String) {
        _ = Self.ignoreSIGPIPEOnce
        self.sessionRef = .local(sessionID)
    }

    init(sessionRef: SessionRef) {
        _ = Self.ignoreSIGPIPEOnce
        self.sessionRef = sessionRef
    }

    deinit {
        stop()
    }

    func start(
        shellPath: String,
        environment: [String: String],
        workingDirectory: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
                let peerVersions = try Self.supportedProtocolVersions(
                    for: self.sessionRef.location,
                    identity: self.daemonIdentity
                )
                guard let version = SessionWireProtocol.macAttachVersion(peerVersions: peerVersions) else {
                    throw Self.unsupportedProtocolError()
                }
                let attachCommand: SessionWireProtocol.ClientCommand
                if version >= SessionWireProtocol.currentVersion {
                    attachCommand = .attachV2(
                        version: version,
                        role: .mac,
                        clientID: self.clientID,
                        sessionID: self.wireSessionID,
                        workingDirectory: workingDirectory.path,
                        shellPath: shellPath,
                        environment: environment
                    )
                } else {
                    attachCommand = .attach(
                        sessionID: self.wireSessionID,
                        workingDirectory: workingDirectory.path,
                        shellPath: shellPath,
                        environment: environment
                    )
                }
                try self.connect()
                guard !self.hasStopped() else {
                    self.closeTransport(terminateBridge: true)
                    return
                }
                self.send(attachCommand)
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    func joinExisting(
        role: SessionWireProtocol.ClientRole = .phone,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
                let peerVersions = try Self.supportedProtocolVersions(
                    for: self.sessionRef.location,
                    identity: self.daemonIdentity
                )
                guard let version = SessionWireProtocol.highestMutualVersion(peerVersions: peerVersions) else {
                    throw Self.unsupportedProtocolError()
                }
                let command: SessionWireProtocol.ClientCommand
                if version >= SessionWireProtocol.currentVersion {
                    command = .joinV2(
                        version: version,
                        role: role,
                        clientID: self.clientID,
                        sessionID: self.wireSessionID
                    )
                } else {
                    // v1 has no join-only verb. /usr/bin/false prevents a missing-session
                    // race from leaving behind a shell while preserving attach to an existing ID.
                    command = .attach(
                        sessionID: self.wireSessionID,
                        workingDirectory: "/",
                        shellPath: "/usr/bin/false",
                        environment: ["TERM": "xterm-256color"]
                    )
                }
                try self.connect()
                self.send(command)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        send(.resize(rows: rows, cols: cols))
    }

    func isCanonicalInputModeEnabled() -> Bool? {
        nil
    }

    func sendInterrupt() {
        send(.interrupt)
    }

    func clearHistory() {
        send(.clearHistory)
    }

    func write(_ string: String, suppressEcho: Bool = false) {
        send(.input(Data(string.utf8)))
    }

    func updateState(
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        runningCommand: String?,
        commandHistory: [String]
    ) {
        let payload = SessionStatePayload(
            title: title,
            cwd: cwd,
            createdAt: createdAt.timeIntervalSince1970,
            commandCount: commandCount,
            runningCommand: runningCommand,
            commandHistory: commandHistory
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        send(.state(data))
    }

    func stop() {
        markStopped()
        // Closing the transport is enough for sessiond to detach this client.
        // Sending DETACH synchronously can beachball the UI if the daemon is wedged.
        closeTransport(terminateBridge: true)
    }

    func kill() {
        markStopped()
        // Keep teardown ordered behind a pending ATTACH. A separate KILL connection can
        // otherwise reach sessiond before that ATTACH creates the session and leave an orphan.
        queue.async { [self] in
            try? transport?.send(SessionWireProtocol.encode(.killAttachedSession))
            closeTransport(terminateBridge: true)
        }
    }

    private func markStopped() {
        lifecycleLock.lock()
        isStopped = true
        didReportExit = true
        lifecycleLock.unlock()
    }

    private func hasStopped() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return isStopped
    }

    private func markExitReported() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isStopped, !didReportExit else { return false }
        didReportExit = true
        return true
    }

    private func reportExit(_ status: Int32) {
        guard markExitReported() else { return }
        closeTransport(terminateBridge: false)
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(status)
        }
    }

    private func closeTransport(terminateBridge: Bool) {
        transport?.close(terminate: terminateBridge)
        transport = nil
        protocolDecoder.reset()
        treatsNextOutputAsLegacyHistory = false
    }

    static func killDetachedSession(sessionID: String) throws {
        try killDetachedSession(sessionRef: .local(sessionID))
    }

    static func killDetachedSession(sessionRef: SessionRef) throws {
        switch sessionRef.location {
        case .local:
            let identity = SessionDaemonIdentity(externalSessionID: sessionRef.sessionID)
            let command = SessionWireProtocol.ClientCommand.kill(sessionID: identity.rawSessionID)
            try sendLocalCommandNoResponse(
                SessionWireProtocol.encode(command),
                namespace: identity.namespace,
                startsDaemon: false
            )
        case .sshHost:
            let command = SessionWireProtocol.ClientCommand.kill(sessionID: sessionRef.sessionID)
            try sendCommandNoResponse(command, location: sessionRef.location)
        case .relayMac:
            throw unsupportedProtocolError()
        }
    }

    static func listSessions(location: SessionLocation = .local) throws -> [SessionMetadata] {
        if case .local = location {
            let canonical = try listLocalSessions(namespace: .canonical, startsDaemon: true)
            let portalDevelopment = (try? listLocalSessions(
                namespace: .portalDevelopment,
                startsDaemon: false
            )) ?? []
            return SessionDaemonInventory.combine(
                canonical: canonical,
                portalDevelopment: portalDevelopment
            )
        }
        let event = try sendSingleResponseCommand(.list, location: location)
        guard case .sessions(let data) = event else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EPROTO),
                userInfo: [NSLocalizedDescriptionKey: "session daemon returned an invalid LIST response"]
            )
        }
        return try JSONDecoder().decode([SessionMetadata].self, from: data)
    }

    private static func listLocalSessions(
        namespace: SessionDaemonNamespace,
        startsDaemon: Bool
    ) throws -> [SessionMetadata] {
        let event = try sendSingleResponseCommand(
            .list,
            location: .local,
            localNamespace: namespace,
            startsLocalDaemon: startsDaemon
        )
        guard case .sessions(let data) = event else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EPROTO),
                userInfo: [NSLocalizedDescriptionKey: "session daemon returned an invalid LIST response"]
            )
        }
        return try JSONDecoder().decode([SessionMetadata].self, from: data)
    }

    private struct SessionStatePayload: Encodable {
        var title: String
        var cwd: String
        var createdAt: TimeInterval
        var commandCount: Int
        var runningCommand: String?
        var commandHistory: [String]
    }

    private func connect() throws {
        let transport: any SessionTransport
        switch sessionRef.location {
        case .local:
            let namespace = daemonIdentity.namespace
            if let process = Self.makeLocalBridgeProcess(namespace: namespace) {
                transport = SSHSessionTransport(
                    queue: queue,
                    process: process,
                    write: Self.writeAll
                )
            } else {
                if namespace == .canonical {
                    try Self.ensureDaemonIsRunning()
                }
                transport = LocalSessionTransport(
                    queue: queue,
                    connect: { try Self.connectToDaemon(namespace: namespace) },
                    write: Self.writeAll
                )
            }
        case .sshHost(let hostID):
            let host = try Self.sshHostRecord(id: hostID)
            transport = SSHSessionTransport(
                queue: queue,
                process: Self.makeSSHBridgeProcess(host: host),
                write: Self.writeAll
            )
        case .relayMac:
            throw Self.unsupportedProtocolError()
        }
        transport.onText = { [weak self] text in self?.consumeProtocolText(text) }
        transport.onExit = { [weak self] status in self?.reportExit(status) }
        transport.onDiagnostic = { [weak self] text in self?.onOutput?(text) }
        self.transport = transport
        do {
            try transport.start()
        } catch {
            transport.close(terminate: true)
            self.transport = nil
            throw error
        }
    }

    private func consumeProtocolText(_ text: String) {
        for event in protocolDecoder.append(text) {
            handleProtocolEvent(event)
        }
    }

    private func handleProtocolEvent(_ event: SessionWireProtocol.ServerEvent) {
        switch event {
        case .output(let text):
            if treatsNextOutputAsLegacyHistory {
                treatsNextOutputAsLegacyHistory = false
                onHistoryOutput?(text)
            } else {
                onOutput?(text)
            }
        case .sequencedOutput(_, let text):
            treatsNextOutputAsLegacyHistory = false
            onOutput?(text)
        case .history(let text):
            treatsNextOutputAsLegacyHistory = false
            onHistoryOutput?(text)
        case .historyPage(_, _, _, let text):
            treatsNextOutputAsLegacyHistory = false
            onHistoryOutput?(text)
        case .snapshot(_, let rows, let cols, let contents):
            onSnapshot?(rows, cols, contents)
        case .presence(let count):
            onPresence?(count)
        case .geometry(let rows, let cols):
            onGeometry?(rows, cols)
        case .protocolVersion, .supportedProtocols:
            break
        case .notFound:
            reportExit(-1)
        case .ready(let created):
            treatsNextOutputAsLegacyHistory = !created
            DispatchQueue.main.async { [weak self] in
                self?.onReady?(created)
            }
        case .exit(let status):
            reportExit(status)
        case .sessions, .unknown:
            break
        }
    }

    private func send(_ command: SessionWireProtocol.ClientCommand) {
        let line = SessionWireProtocol.encode(command)
        do {
            try transport?.send(line)
        } catch {
            reportExit(-1)
        }
    }

    @discardableResult
    private static func sendSingleResponseCommand(
        _ command: SessionWireProtocol.ClientCommand,
        location: SessionLocation,
        localNamespace: SessionDaemonNamespace = .canonical,
        startsLocalDaemon: Bool = true
    ) throws -> SessionWireProtocol.ServerEvent {
        let line = SessionWireProtocol.encode(command)
        switch location {
        case .local:
            if let process = makeLocalBridgeProcess(namespace: localNamespace) {
                let output = try runLocalBridgeCommand(process, command: line)
                let response = String(decoding: output, as: UTF8.self)
                    .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map(String.init) ?? ""
                return SessionWireProtocol.Decoder.decode(response)
            }
            if startsLocalDaemon {
                try ensureDaemonIsRunning()
            }
            let fd = try connectToDaemon(namespace: localNamespace)
            defer { close(fd) }
            try writeAll(line + "\n", to: fd)
            return SessionWireProtocol.Decoder.decode(try readLine(from: fd))
        case .sshHost(let hostID):
            let host = try sshHostRecord(id: hostID)
            let output = try runSSHBridgeCommand(host: host, command: line)
            let response = String(decoding: output, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            return SessionWireProtocol.Decoder.decode(response)
        case .relayMac:
            throw unsupportedProtocolError()
        }
    }

    private static func supportedProtocolVersions(
        for location: SessionLocation,
        identity: SessionDaemonIdentity
    ) throws -> [UInt16] {
        let event = try sendSingleResponseCommand(
            .supportedProtocols,
            location: location,
            localNamespace: identity.namespace,
            startsLocalDaemon: identity.namespace == .canonical
        )
        guard case .supportedProtocols(let peerVersions) = event else {
            // Protocol v1 predates discovery. A daemon that closes this probe is a v1 peer.
            return [SessionWireProtocol.previousVersion]
        }
        return peerVersions
    }

    private static func unsupportedProtocolError() -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EPROTONOSUPPORT),
            userInfo: [NSLocalizedDescriptionKey: "session daemon has no compatible protocol version"]
        )
    }

    private static func sendCommandNoResponse(
        _ command: SessionWireProtocol.ClientCommand,
        location: SessionLocation
    ) throws {
        let line = SessionWireProtocol.encode(command)
        switch location {
        case .local:
            try sendLocalCommandNoResponse(line, namespace: .canonical, startsDaemon: true)
        case .sshHost(let hostID):
            let host = try sshHostRecord(id: hostID)
            let process = makeSSHBridgeProcess(host: host, batchMode: true)
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            try writeAll(line + "\n", to: inputPipe.fileHandleForWriting.fileDescriptor)
            try inputPipe.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    process.terminate()
                }
            }
        case .relayMac:
            throw unsupportedProtocolError()
        }
    }

    private static func sendLocalCommandNoResponse(
        _ command: String,
        namespace: SessionDaemonNamespace,
        startsDaemon: Bool
    ) throws {
        if startsDaemon {
            try ensureDaemonIsRunning()
        }

        let fd: Int32
        do {
            fd = try connectToDaemon(namespace: namespace)
        } catch {
            if !startsDaemon, isMissingDaemonConnectionError(error) {
                return
            }
            throw error
        }

        defer { close(fd) }
        try writeAll(command + "\n", to: fd)
    }

    private static func isMissingDaemonConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return false }
        return nsError.code == Int(ENOENT) || nsError.code == Int(ECONNREFUSED)
    }

    private static func runSSHBridgeCommand(host: SSHHostRecord, command: String) throws -> Data {
        let process = makeSSHBridgeProcess(host: host, batchMode: true)
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let output = try runProcess(process)
        try writeAll(command + "\n", to: inputPipe.fileHandleForWriting.fileDescriptor)
        try inputPipe.fileHandleForWriting.close()
        return try output()
    }

    private static func runLocalBridgeCommand(_ process: Process, command: String) throws -> Data {
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let output = try runProcess(process)
        try writeAll(command + "\n", to: inputPipe.fileHandleForWriting.fileDescriptor)
        try inputPipe.fileHandleForWriting.close()
        return try output()
    }

    private static func makeLocalBridgeProcess(namespace: SessionDaemonNamespace) -> Process? {
        guard let path = SessionWireProtocol.localBridgeCandidates(
            forExecutable: CommandLine.arguments[0]
        ).first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        if namespace == .portalDevelopment {
            var environment = ProcessInfo.processInfo.environment
            environment["PORTAL_SESSIOND_SOCKET"] = socketPath(namespace: namespace)
            environment["PORTAL_SESSIOND_REQUIRE_EXISTING"] = "1"
            process.environment = environment
        }
        return process
    }

    static func runSSHBridgeSubcommand(
        hostID: String,
        arguments: [String],
        input: Data,
        timeout: TimeInterval = 5
    ) throws -> Data {
        let host = try sshHostRecord(id: hostID)
        let process = makeSSHBridgeProcess(host: host, batchMode: true, arguments: arguments)
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let output = try runProcess(process, timeout: timeout)
        try writeAll(input, to: inputPipe.fileHandleForWriting.fileDescriptor)
        try inputPipe.fileHandleForWriting.close()
        return try output()
    }

    static func runLocalBridgeSubcommand(
        arguments: [String],
        input: Data,
        timeout: TimeInterval = 5
    ) throws -> Data {
        guard let process = makeLocalBridgeProcess(namespace: .canonical) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "Portal session bridge was not found"]
            )
        }
        process.arguments = arguments
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let output = try runProcess(process, timeout: timeout)
        try writeAll(input, to: inputPipe.fileHandleForWriting.fileDescriptor)
        try inputPipe.fileHandleForWriting.close()
        return try output()
    }

    private static func runProcess(_ process: Process, timeout: TimeInterval = 5) throws -> () throws -> Data {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        return {
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutWorkItem.cancel()
            if process.terminationStatus == SIGTERM {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ETIMEDOUT),
                    userInfo: [NSLocalizedDescriptionKey: "SSH command timed out"]
                )
            }
            if process.terminationStatus != 0 {
                let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "SSH command failed" : errorText]
                )
            }
            return output
        }
    }

    private static func writeAll(_ string: String, to fd: Int32) throws {
        _ = ignoreSIGPIPEOnce
        guard let data = string.data(using: .utf8) else { return }
        try writeAll(data, to: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        _ = ignoreSIGPIPEOnce
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else if written == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(1_000)
                } else {
                    throw NSError(
                        domain: NSPOSIXErrorDomain,
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "socket write failed: \(String(cString: strerror(errno)))"]
                    )
                }
            }
        }
    }

    private static func readLine(from fd: Int32) throws -> String {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            if count == 1 {
                if byte == UInt8(ascii: "\n") {
                    break
                }
                bytes.append(byte)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw posixError("read")
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func connectToDaemon(namespace: SessionDaemonNamespace = .canonical) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket")
        }

        do {
            try connect(fd: fd, path: socketPath(namespace: namespace))
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func connect(fd: Int32, path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "daemon socket path is too long"]
            )
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for index in pathBytes.indices {
                buffer[index] = UInt8(bitPattern: pathBytes[index])
            }
        }

        let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, length)
            }
        }
        guard result == 0 else {
            throw posixError("connect")
        }
    }

    private static func ensureDaemonIsRunning() throws {
        daemonStartupLock.lock()
        defer { daemonStartupLock.unlock() }

        if (try? daemonInventoryIsEmpty()) != nil {
            return
        } else if let fd = try? connectToDaemon() {
            close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EPROTO),
                userInfo: [NSLocalizedDescriptionKey: "connected session daemon cannot report inventory"]
            )
        }

        let helper = try sessiondHelperPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["PORTAL_SESSIOND_SOCKET"] = socketPath(namespace: .canonical)
        if helper.contains("/target/debug/") || helper.contains("/target/app/debug/") {
            env["PORTAL_SESSIOND_ALLOW_DEBUG_CLIENT"] = "1"
        }
        process.environment = env
        try process.run()

        let deadline = Date().addingTimeInterval(2)
        var lastError: Error?
        while Date() < deadline {
            do {
                let fd = try connectToDaemon()
                close(fd)
                return
            } catch {
                lastError = error
                usleep(50_000)
            }
        }
        throw lastError ?? posixError("connect")
    }

    private static func daemonInventoryIsEmpty() throws -> Bool {
        let fd = try connectToDaemon()
        defer { close(fd) }
        try writeAll("LIST\n", to: fd)
        guard case .sessions(let data) = SessionWireProtocol.Decoder.decode(try readLine(from: fd)) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EPROTO),
                userInfo: [NSLocalizedDescriptionKey: "session daemon returned an invalid LIST response"]
            )
        }
        return data == Data("[]".utf8)
    }

    private static func sessiondHelperPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["PORTAL_SESSIOND"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("portal-sessiond", isDirectory: false)
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for candidate in [
            "target/debug/portal-sessiond",
            "target/release/portal-sessiond"
        ] {
            let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(candidate)
                .path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOENT),
            userInfo: [NSLocalizedDescriptionKey: "portal-sessiond helper was not found"]
        )
    }

    private static func sshHostRecord(id: String) throws -> SSHHostRecord {
        let stored = loadSSHHosts()
        if let host = stored.hosts.first(where: { $0.id == id }) {
            return host
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOENT),
            userInfo: [NSLocalizedDescriptionKey: "SSH host is not configured"]
        )
    }

    static func loadSSHHosts() -> StoredSSHHosts {
        let url = sshHostsURL()
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredSSHHosts.self, from: data)
        else {
            return StoredSSHHosts(hosts: [])
        }
        return stored
    }

    private static func makeSSHBridgeProcess(
        host: SSHHostRecord,
        batchMode: Bool = false,
        arguments: [String] = []
    ) -> Process {
        makeSSHProcess(
            host: host,
            command: shellCommand(execPath: host.remoteHelperPath, arguments: arguments),
            batchMode: batchMode
        )
    }

    private static func makeSSHProcess(host: SSHHostRecord, command: String, batchMode: Bool = false) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-T"]
        try? FileManager.default.createDirectory(
            at: sshControlDirectory(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sshControlDirectory().path
        )
        arguments += [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=30s",
            "-o", "ControlPath=\(sshControlPath(for: host).path)"
        ]
        if batchMode {
            arguments += [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2"
            ]
        }
        if host.port != 22 {
            arguments += ["-p", String(host.port)]
        }
        arguments.append("\(host.user)@\(host.hostname)")
        arguments.append(command)
        process.arguments = arguments
        return process
    }

    private static func sshControlDirectory() -> URL {
        URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("vaultty-\(getuid())", isDirectory: true)
    }

    private static func sshControlPath(for host: SSHHostRecord) -> URL {
        let name = host.id
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .map(String.init)
            .joined()
        return sshControlDirectory().appendingPathComponent(name, isDirectory: false)
    }

    private static func shellCommand(execPath: String, arguments: [String] = []) -> String {
        let argumentText = arguments.map(shellQuote).joined(separator: " ")
        if argumentText.isEmpty {
            return "exec \(shellPathExpression(execPath))"
        }
        return "exec \(shellPathExpression(execPath)) \(argumentText)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func shellPathExpression(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let relativePath = String(path.dropFirst(2))
            return "\"$HOME/\(doubleQuoteEscaped(relativePath))\""
        }
        return shellQuote(path)
    }

    private static func doubleQuoteEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func socketPath(namespace: SessionDaemonNamespace) -> String {
        if namespace == .canonical,
           let override = ProcessInfo.processInfo.environment["PORTAL_SESSIOND_SOCKET"],
           !override.isEmpty {
            return override
        }
        let applicationSupportName = namespace == .canonical ? "Vaultty" : "Portal Terminal"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportName, isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("sessiond.sock", isDirectory: false)
            .path
    }

    private static func sshHostsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vaultty", isDirectory: true)
            .appendingPathComponent("hosts.json", isDirectory: false)
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}

extension PtySession: TerminalSession {}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
