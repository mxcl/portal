import Foundation
import Darwin

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
    var onExit: ((Int32) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPresence: ((Int) -> Void)?

    private let sessionRef: SessionRef
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
        let attachCommand = SessionWireProtocol.ClientCommand.attachV2(
            version: SessionWireProtocol.currentVersion,
            role: .mac,
            clientID: clientID,
            sessionID: sessionRef.sessionID,
            workingDirectory: workingDirectory.path,
            shellPath: shellPath,
            environment: environment
        )

        queue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
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

    func joinExisting(completion: @escaping (Result<Void, Error>) -> Void) {
        let command = SessionWireProtocol.ClientCommand.joinV2(
            version: SessionWireProtocol.currentVersion,
            role: .phone,
            clientID: clientID,
            sessionID: sessionRef.sessionID
        )
        queue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
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
        let command = SessionWireProtocol.ClientCommand.kill(sessionID: sessionRef.sessionID)
        switch sessionRef.location {
        case .local:
            try sendLocalCommandNoResponse(SessionWireProtocol.encode(command), startsDaemon: false)
        case .sshHost:
            try sendCommandNoResponse(command, location: sessionRef.location)
        }
    }

    static func listSessions(location: SessionLocation = .local) throws -> [SessionMetadata] {
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

    static func remoteStoredSessionMetadata(host: SSHHostRecord) throws -> [SessionMetadata] {
        let data = try runSSHCommand(
            host: host,
            command: "cat \"$HOME/Library/Application Support/Vaultty/sessions.json\" 2>/dev/null || true",
            batchMode: true
        )
        guard !data.isEmpty else { return [] }
        let stored = try JSONDecoder().decode(RemoteStoredSessions.self, from: data)
        return (stored.visibleTabs + stored.closedTabs)
            .filter { ($0.commandCount ?? 0) > 0 }
            .map { tab in
                SessionMetadata(
                    sessionID: tab.sessionID,
                    title: tab.title,
                    cwd: tab.cwd,
                    createdAt: tab.createdAt ?? Date.distantPast,
                    commandCount: tab.commandCount ?? 0,
                    runningCommand: tab.runningCommand,
                    commandHistory: tab.commandHistory ?? []
                )
            }
    }

    static func remoteSessionDefaults(host: SSHHostRecord) throws -> RemoteSessionDefaults {
        let data = try runSSHCommand(
            host: host,
            command: "printf '%s\\000%s\\000' \"$HOME\" \"${SHELL:-/bin/sh}\"",
            batchMode: true
        )
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count >= 2,
              let homeDirectory = String(data: fields[0], encoding: .utf8),
              let shellPath = String(data: fields[1], encoding: .utf8),
              !homeDirectory.isEmpty,
              !shellPath.isEmpty
        else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EPROTO),
                userInfo: [NSLocalizedDescriptionKey: "SSH host returned invalid session defaults"]
            )
        }
        return RemoteSessionDefaults(homeDirectory: homeDirectory, shellPath: shellPath)
    }

    private struct SessionStatePayload: Encodable {
        var title: String
        var cwd: String
        var createdAt: TimeInterval
        var commandCount: Int
        var runningCommand: String?
        var commandHistory: [String]
    }

    private struct RemoteStoredSessions: Decodable {
        var visibleTabs: [RemoteStoredTab]
        var closedTabs: [RemoteStoredTab]
    }

    private struct RemoteStoredTab: Decodable {
        var sessionID: String
        var title: String
        var cwd: String
        var createdAt: Date?
        var commandCount: Int?
        var runningCommand: String?
        var commandHistory: [String]?
    }

    private func connect() throws {
        let transport: any SessionTransport
        switch sessionRef.location {
        case .local:
            try Self.ensureDaemonIsRunning()
            transport = LocalSessionTransport(
                queue: queue,
                connect: Self.connectToDaemon,
                write: Self.writeAll
            )
        case .sshHost(let hostID):
            let host = try Self.sshHostRecord(id: hostID)
            transport = SSHSessionTransport(
                queue: queue,
                process: Self.makeSSHBridgeProcess(host: host),
                write: Self.writeAll
            )
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
        case .snapshot:
            // macOS replays the retained byte history; phones render this canonical screen directly.
            break
        case .presence(let count):
            onPresence?(count)
        case .protocolVersion, .geometry:
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
        location: SessionLocation
    ) throws -> SessionWireProtocol.ServerEvent {
        let line = SessionWireProtocol.encode(command)
        switch location {
        case .local:
            try ensureDaemonIsRunning()
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

    private static func sendLocalCommandNoResponse(_ command: String, startsDaemon: Bool) throws {
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

    private static func runSSHCommand(host: SSHHostRecord, command: String, batchMode: Bool) throws -> Data {
        let process = makeSSHProcess(host: host, command: command, batchMode: batchMode)
        let output = try runProcess(process)
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

    private static func connectToDaemon() throws -> Int32 {
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

        if (try? connectToDaemon()).map({ fd in close(fd); return true }) == true {
            return
        }

        let helper = try sessiondHelperPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["VAULTTY_SESSIOND_SOCKET"] = socketPath()
        if helper.contains("/target/debug/") || helper.contains("/target/app/debug/") {
            env["VAULTTY_SESSIOND_ALLOW_DEBUG_CLIENT"] = "1"
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

    private static func sessiondHelperPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["VAULTTY_SESSIOND"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("vaultty-sessiond", isDirectory: false)
            .path
        if FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for candidate in [
            "target/debug/vaultty-sessiond",
            "target/release/vaultty-sessiond"
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
            userInfo: [NSLocalizedDescriptionKey: "vaultty-sessiond helper was not found"]
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

    static func saveSSHHosts(_ hosts: StoredSSHHosts) throws {
        let url = sshHostsURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(hosts)
        try data.write(to: url, options: .atomic)
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

    private static func socketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["VAULTTY_SESSIOND_SOCKET"],
           !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Vaultty", isDirectory: true)
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

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
