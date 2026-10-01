#if os(macOS)
import Foundation
import Darwin
import Security

extension PtySession {
    var supportsBinaryInput: Bool { true }

    func write(_ string: String, suppressEcho: Bool = false) {
        write(Data(string.utf8), suppressEcho: suppressEcho)
    }

    func write(_ data: Data) {
        write(data, suppressEcho: false)
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

final class ProcessSessionTransport: SessionTransport {
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
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }
        try process.run()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        error = errorPipe.fileHandleForReading

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                finished.leave()
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
                finished.leave()
                return
            }
            self?.queue.async {
                self?.errorOutput.append(data)
            }
        }
        finished.notify(queue: queue) { [weak self] in
            guard let self else { return }
            let message = String(data: self.errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if self.process.terminationStatus != 0, !message.isEmpty {
                self.onDiagnostic?("\nTerminal connection failed: \(message)\n")
            }
            self.onExit?(self.process.terminationStatus)
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
    var onGeometry: ((UInt16, UInt16) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPresence: ((Int) -> Void)?
    var onInterruptReconciled: (() -> Void)?

    private let sessionRef: SessionRef
    private var wireSessionID: String { sessionRef.sessionID }
    private let clientID = UUID().uuidString
    private let queue = DispatchQueue(label: "dev.mxcl.portal.session-client")
    private var transport: (any SessionTransport)?
    var onConnectionChange: ((Bool) -> Void)?
    private var hasAttached = false
    private var attachCommand: SessionWireProtocol.ClientCommand?
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var transportGeneration = 0
    private var lastGeometry: (rows: UInt16, cols: UInt16)?
    private var protocolDecoder = SessionWireProtocol.Decoder()
    private var pendingScreen = ""
    private var treatsNextOutputAsLegacyHistory = false
    private var isInterruptReconciliationScheduled = false
    private let lifecycleLock = NSLock()
    private var isStopped = false
    private var didReportExit = false
    private static let daemonStartupLock = NSLock()
    private static let currentDaemonRequirement = """
        anchor apple generic and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists and \
        certificate leaf[field.1.2.840.113635.100.6.1.13] exists and \
        certificate leaf[subject.OU] = "ZU76A67LGU" and \
        identifier "dev.mxcl.portal.sessiond"
        """
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
        reconnectWorkItem?.cancel()
        transport?.close(terminate: true)
    }

    func start(
        shellPath: String,
        environment: [String: String],
        workingDirectory: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            self.attachCommand = .attachV2(version: SessionWireProtocol.currentVersion, role: .mac,
                                           clientID: self.clientID, sessionID: self.wireSessionID,
                                           workingDirectory: workingDirectory.path, shellPath: shellPath,
                                           environment: environment)
            do {
                let peerVersions = try Self.supportedProtocolVersions(
                    for: self.sessionRef.location
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
                self.attachCommand = attachCommand
                try self.connect()
                guard !self.hasStopped() else {
                    self.closeTransport(terminateBridge: true)
                    return
                }
                try self.transport?.send(SessionWireProtocol.encode(attachCommand))
                DispatchQueue.main.async {
                    completion(.success(()))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                if case .sshHost = self.sessionRef.location,
                   (error as NSError).code != Int(EPROTONOSUPPORT) {
                    self.reconnect()
                }
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        queue.async { [weak self] in
            self?.lastGeometry = (rows, cols)
            self?.sendNow(.resize(rows: rows, cols: cols))
        }
    }

    func sendInterrupt() {
        send(.interrupt)
        queue.async { [weak self] in
            self?.scheduleInterruptReconciliation()
        }
    }

    func clearHistory() {
        send(.clearHistory)
    }

    func write(_ data: Data, suppressEcho: Bool = false) {
        send(.input(data))
    }

    func updateState(
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        lastCommandAt: Date?,
        runningCommand: String?,
        commandHistory: [String]
    ) {
        let payload = SessionStatePayload(
            title: title,
            cwd: cwd,
            createdAt: createdAt.timeIntervalSince1970,
            commandCount: commandCount,
            lastCommandAt: lastCommandAt?.timeIntervalSince1970,
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
        queue.async { [self] in
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            closeTransport(terminateBridge: true)
        }
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
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        closeTransport(terminateBridge: true)
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(status)
        }
    }

    private func closeTransport(terminateBridge: Bool) {
        transportGeneration &+= 1
        transport?.close(terminate: terminateBridge)
        transport = nil
        pendingScreen = ""
        protocolDecoder.reset()
        treatsNextOutputAsLegacyHistory = false
    }

    static func killDetachedSession(sessionID: String) throws {
        try killDetachedSession(sessionRef: .local(sessionID))
    }

    static func killDetachedSession(sessionRef: SessionRef) throws {
        switch sessionRef.location {
        case .local:
            let command = SessionWireProtocol.ClientCommand.kill(sessionID: sessionRef.sessionID)
            try sendLocalCommandNoResponse(
                SessionWireProtocol.encode(command),
                startsDaemon: false
            )
        case .sshHost:
            let command = SessionWireProtocol.ClientCommand.kill(sessionID: sessionRef.sessionID)
            try sendCommandNoResponse(command, location: sessionRef.location)
        }
    }

    static func listSessions(location: SessionLocation = .local) throws -> [SessionMetadata] {
        if case .local = location {
            return try listLocalSessions(startsDaemon: true)
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
        startsDaemon: Bool
    ) throws -> [SessionMetadata] {
        let event = try sendSingleResponseCommand(
            .list,
            location: .local,
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
        var lastCommandAt: TimeInterval?
        var runningCommand: String?
        var commandHistory: [String]
    }

    private func connect() throws {
        let transport: any SessionTransport
        switch sessionRef.location {
        case .local:
                if let process = try Self.makeLocalBridgeProcess() {
                transport = ProcessSessionTransport(
                    queue: queue,
                    process: process,
                    write: Self.writeAll
                )
            } else {
                try Self.ensureDaemonIsRunning()
                transport = LocalSessionTransport(
                    queue: queue,
                    connect: { try Self.connectToDaemon() },
                    write: Self.writeAll
                )
            }
        case .sshHost(let hostID):
            let host = try Self.sshHostRecord(id: hostID)
            transport = ProcessSessionTransport(
                queue: queue,
                process: Self.makeSSHBridgeProcess(host: host),
                write: Self.writeAll
            )
        }
        let generation = transportGeneration
        transport.onText = { [weak self] text in
            guard let self, generation == self.transportGeneration, !self.hasStopped() else { return }
            self.consumeProtocolText(text)
        }
        transport.onExit = { [weak self] _ in
            guard let self, generation == self.transportGeneration, !self.hasStopped() else { return }
            self.reconnect()
        }
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
            // Fullscreen content belongs to the live screen, after command-history replay.
            onHistoryOutput?(text + pendingScreen)
            pendingScreen = ""
        case .snapshot(_, _, _, let contents):
            pendingScreen = contents.hasPrefix("\u{1B}[?1049h") ? contents : ""
        case .presence(let count):
            onPresence?(count)
        case .geometry(let rows, let cols):
            onGeometry?(rows, cols)
        case .protocolVersion, .supportedProtocols:
            break
        case .notFound:
            reportExit(-1)
        case .ready(let created):
            hasAttached = true
            reconnectAttempt = 0
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            if let geometry = lastGeometry {
                sendNow(.resize(rows: geometry.rows, cols: geometry.cols))
            }
            DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(true) }
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
        queue.async { [weak self] in self?.sendNow(command) }
    }

    private func sendNow(_ command: SessionWireProtocol.ClientCommand) {
        guard !hasStopped() else { return }
        do {
            try transport?.send(SessionWireProtocol.encode(command))
        } catch {
            reconnect()
        }
    }

    private func reconnect() {
        guard !hasStopped(), reconnectWorkItem == nil else { return }
        closeTransport(terminateBridge: true)
        DispatchQueue.main.async { [weak self] in self?.onConnectionChange?(false) }
        let delay = min(pow(2, Double(min(reconnectAttempt, 4))), 15)
        reconnectAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hasStopped() else { return }
            self.reconnectWorkItem = nil
            do {
                let versions = try Self.supportedProtocolVersions(for: self.sessionRef.location)
                guard let version = SessionWireProtocol.macAttachVersion(peerVersions: versions) else {
                    throw Self.unsupportedProtocolError()
                }
                let command: SessionWireProtocol.ClientCommand
                if self.hasAttached {
                    // Reconnection must never create a replacement shell or repeat user input.
                    command = Self.reattachCommand(version: version, clientID: self.clientID,
                                                   sessionID: self.wireSessionID)
                } else if let initial = self.attachCommand {
                    command = initial
                } else {
                    return
                }
                try self.connect()
                try self.transport?.send(SessionWireProtocol.encode(command))
            } catch {
                self.reconnect()
            }
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func reattachCommand(version: UInt16, clientID: String, sessionID: String) -> SessionWireProtocol.ClientCommand {
        if version >= SessionWireProtocol.currentVersion {
            return .joinV2(version: version, role: .mac, clientID: clientID, sessionID: sessionID)
        }
        // A v1 peer has no join-only verb. A missing session exits without starting a shell.
        return .attach(sessionID: sessionID, workingDirectory: "/", shellPath: "/usr/bin/false",
                       environment: ["TERM": "xterm-256color"])
    }

    private func scheduleInterruptReconciliation() {
        guard !isInterruptReconciliationScheduled else { return }
        isInterruptReconciliationScheduled = true
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
                let event = try Self.sendSingleResponseCommand(
                    .list,
                    location: self.sessionRef.location,
                    startsLocalDaemon: false
                )
                guard case .sessions(let data) = event else {
                    self.isInterruptReconciliationScheduled = false
                    return
                }
                let sessions = try JSONDecoder().decode([SessionMetadata].self, from: data)
                guard Self.commandIsStillRunning(in: sessions, sessionID: self.wireSessionID) else {
                    self.isInterruptReconciliationScheduled = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onInterruptReconciled?()
                    }
                    return
                }
                self.isInterruptReconciliationScheduled = false
                self.scheduleInterruptReconciliation()
            } catch {
                self.isInterruptReconciliationScheduled = false
            }
        }
    }

    private static func commandIsStillRunning(
        in sessions: [SessionMetadata],
        sessionID: String
    ) -> Bool {
        sessions.first(where: { $0.sessionID == sessionID })?.runningCommand != nil
    }

    static func interruptReconciliationSelfTest() -> Bool {
        let finished = SessionMetadata(
            sessionID: "session",
            title: "",
            cwd: "/",
            createdAt: .now,
            commandCount: 1,
            runningCommand: nil,
            commandHistory: []
        )
        let running = SessionMetadata(
            sessionID: "session",
            title: "",
            cwd: "/",
            createdAt: .now,
            commandCount: 1,
            runningCommand: "sleep 30",
            commandHistory: []
        )
        return !commandIsStillRunning(in: [], sessionID: "session")
            && !commandIsStillRunning(in: [finished], sessionID: "session")
            && commandIsStillRunning(in: [running], sessionID: "session")
    }

    @discardableResult
    private static func sendSingleResponseCommand(
        _ command: SessionWireProtocol.ClientCommand,
        location: SessionLocation,
        startsLocalDaemon: Bool = true
    ) throws -> SessionWireProtocol.ServerEvent {
        let line = SessionWireProtocol.encode(command)
        switch location {
        case .local:
            if let process = try makeLocalBridgeProcess() {
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
            let fd = try connectToDaemon()
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
        }
    }

    private static func supportedProtocolVersions(
        for location: SessionLocation
    ) throws -> [UInt16] {
        let event = try sendSingleResponseCommand(
            .supportedProtocols,
            location: location
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
            try sendLocalCommandNoResponse(line, startsDaemon: true)
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
        }
    }

    private static func sendLocalCommandNoResponse(
        _ command: String,
        startsDaemon: Bool
    ) throws {
        if startsDaemon {
            try ensureDaemonIsRunning()
        }

        let fd: Int32
        do {
            fd = try connectToDaemon()
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

    private static func makeLocalBridgeProcess() throws -> Process? {
        guard let path = SessionWireProtocol.localBridgeCandidates(
            forExecutable: CommandLine.arguments[0]
        ).first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["PORTAL_SESSIOND"] = try sessiondHelperPath()
        process.environment = environment
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
        guard let process = try makeLocalBridgeProcess() else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOENT),
                userInfo: [NSLocalizedDescriptionKey: "Portal terminal bridge was not found"]
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

    private static func setReadTimeout(fd: Int32, microseconds: Int32) throws {
        var timeout = timeval(tv_sec: 0, tv_usec: microseconds)
        let timeoutSize = socklen_t(MemoryLayout.size(ofValue: timeout))
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                timeoutSize
            )
        }
        guard result == 0 else { throw posixError("setsockopt") }
    }

    private static func connectToDaemon() throws -> Int32 {
        let fd = try connectSocketToDaemon()
        let identity: DaemonPeerIdentity
        do {
            identity = try daemonPeerIdentity(fd: fd)
            guard identity != .untrusted else {
                throw NSError(
                    domain: NSOSStatusErrorDomain,
                    code: Int(errSecCSReqFailed),
                    userInfo: [NSLocalizedDescriptionKey: "session daemon is not trusted by Portal"]
                )
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    private static func connectSocketToDaemon(
        
    ) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket")
        }

        do {
            try connect(fd: fd, path: socketPath())
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private enum DaemonPeerIdentity {
        case current
        case untrusted
    }

    private static func daemonPeerIdentity(fd: Int32) throws -> DaemonPeerIdentity {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw posixError("getpeereid")
        }
        guard uid == geteuid() else { return .untrusted }

        var token = audit_token_t()
        var tokenLength = socklen_t(MemoryLayout<audit_token_t>.size)
        let tokenStatus = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, SOL_LOCAL, 0x006, pointer, &tokenLength)
        }
        guard tokenStatus == 0,
              tokenLength == socklen_t(MemoryLayout<audit_token_t>.size) else {
            throw posixError("LOCAL_PEERTOKEN")
        }

        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard status == errSecSuccess, let code else {
            return .untrusted
        }
        if SecCodeCheckValidity(code, [], try codeRequirement(currentDaemonRequirement)) == errSecSuccess {
            return .current
        }
        return .untrusted
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
        env["PORTAL_SESSIOND_SOCKET"] = socketPath()
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
        if let bundled = bundledSessiondAppURL() {
            return try stageSessiondApp(bundled)
        }

        for candidate in [
            "TerminalHelpers/target/debug/portal-sessiond",
            "TerminalHelpers/target/release/portal-sessiond"
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

    private static func bundledSessiondAppURL() -> URL? {
        let name = "Portal Session Helper.app"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .deletingLastPathComponent()
        var candidates = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
        ]
        if executableDirectory.lastPathComponent == "MacOS" {
            candidates.append(
                executableDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Helpers", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
            )
        } else if executableDirectory.lastPathComponent == "Helpers" {
            candidates.append(executableDirectory.appendingPathComponent(name, isDirectory: true))
        }
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private static func stageSessiondApp(_ source: URL) throws -> String {
        let codeHash = try verifiedCodeHash(of: source)
        let fileManager = FileManager.default
        let base = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Portal/Terminal/helpers/sessiond", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)

        let destinationDirectory = base.appendingPathComponent(codeHash, isDirectory: true)
        let destination = destinationDirectory
            .appendingPathComponent("Portal Session Helper.app", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard try verifiedCodeHash(of: destination) == codeHash else {
                throw stagedHelperIdentityError()
            }
            return sessiondExecutable(in: destination).path
        }

        let temporaryDirectory = base
            .appendingPathComponent(".\(UUID().uuidString).staging", isDirectory: true)
        let temporaryApp = temporaryDirectory
            .appendingPathComponent("Portal Session Helper.app", isDirectory: true)
        do {
            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryDirectory.path
            )
            try fileManager.copyItem(at: source, to: temporaryApp)
            guard try verifiedCodeHash(of: temporaryApp) == codeHash else {
                throw stagedHelperIdentityError()
            }
            do {
                try fileManager.moveItem(at: temporaryDirectory, to: destinationDirectory)
            } catch where fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: temporaryDirectory)
                guard try verifiedCodeHash(of: destination) == codeHash else {
                    throw stagedHelperIdentityError()
                }
            }
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
        return sessiondExecutable(in: destination).path
    }

    private static func sessiondExecutable(in app: URL) -> URL {
        app.appendingPathComponent("Contents/MacOS/portal-sessiond", isDirectory: false)
    }

    private static func verifiedCodeHash(of app: URL) throws -> String {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw securityError("load session helper signature", status: status)
        }
        let requirement = try codeRequirement(currentDaemonRequirement)
        let validationFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        status = SecStaticCodeCheckValidity(staticCode, validationFlags, requirement)
        guard status == errSecSuccess else {
            throw securityError("validate session helper signature", status: status)
        }

        var signingInformation: CFDictionary?
        status = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard status == errSecSuccess,
              let information = signingInformation as? [CFString: Any],
              let data = information[kSecCodeInfoUnique] as? Data,
              !data.isEmpty else {
            if status != errSecSuccess {
                throw securityError("read session helper code hash", status: status)
            }
            throw stagedHelperIdentityError()
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func codeRequirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw securityError("create code-signing requirement", status: status)
        }
        return requirement
    }

    private static func securityError(_ operation: String, status: OSStatus) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(detail)"]
        )
    }

    private static func stagedHelperIdentityError() -> NSError {
        NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(errSecCSBadObjectFormat),
            userInfo: [NSLocalizedDescriptionKey: "staged session helper identity changed"]
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

    private static let hostsLock = NSLock()
    private static var configuredHosts: [SSHHostRecord] = []

    static func configureSSHHosts(_ hosts: [TerminalHost]) {
        hostsLock.withLock {
            configuredHosts = hosts.filter { !$0.peer.isEmpty && !$0.peer.hasPrefix("-") }.map {
                SSHHostRecord(id: $0.id, alias: $0.name, hostname: $0.peer, user: "", port: 22,
                              remoteHelperPath: $0.helperPath, directory: $0.directory, enrolled: true)
            }
        }
    }

    static func loadSSHHosts() -> StoredSSHHosts {
        hostsLock.withLock { StoredSSHHosts(hosts: configuredHosts) }
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
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                         "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        arguments += [
            "-o", "ControlMaster=no", "-o", "ControlPath=none"
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
        arguments.append("--")
        arguments.append(host.user.isEmpty ? host.hostname : "\(host.user)@\(host.hostname)")
        arguments.append(command)
        process.arguments = arguments
        return process
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

    private static func socketPath() -> String {
        if let override = (ProcessInfo.processInfo.environment["PORTAL_SESSIOND_SOCKET"] ?? ProcessInfo.processInfo.environment["GITINUUM_SESSIOND_SOCKET"]),
           !override.isEmpty {
            return override
        }
        let applicationSupportName = "Portal/Terminal"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(applicationSupportName, isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("sessiond.sock", isDirectory: false)
            .path
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}


private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

#endif
