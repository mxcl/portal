import Foundation
import Darwin

struct SSHHostRecord: Codable, Equatable {
    var id: String
    var alias: String
    var hostname: String
    var user: String
    var port: Int
    var remoteHelperPath: String
    var enrolled: Bool
}

struct StoredSSHHosts: Codable {
    var hosts: [SSHHostRecord]
}

enum SessionLocation: Codable, Hashable {
    case local
    case sshHost(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case hostID
    }

    private enum Kind: String, Codable {
        case local
        case ssh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .local:
            self = .local
        case .ssh:
            self = .sshHost(try container.decode(String.self, forKey: .hostID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        case .sshHost(let hostID):
            try container.encode(Kind.ssh, forKey: .kind)
            try container.encode(hostID, forKey: .hostID)
        }
    }
}

struct SessionRef: Codable, Hashable {
    var location: SessionLocation
    var sessionID: String

    static func local(_ sessionID: String) -> SessionRef {
        SessionRef(location: .local, sessionID: sessionID)
    }
}

struct SessionMetadata: Decodable {
    var sessionID: String
    var title: String
    var cwd: String
    var createdAt: Date
    var commandCount: Int
    var runningCommand: String?
    var commandHistory: [String]
    var attachedClientCount: Int

    init(
        sessionID: String,
        title: String,
        cwd: String,
        createdAt: Date,
        commandCount: Int,
        runningCommand: String?,
        commandHistory: [String],
        attachedClientCount: Int = 0
    ) {
        self.sessionID = sessionID
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.commandCount = commandCount
        self.runningCommand = runningCommand
        self.commandHistory = commandHistory
        self.attachedClientCount = attachedClientCount
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case title
        case cwd
        case createdAt
        case commandCount
        case runningCommand
        case commandHistory
        case attachedClientCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        let unixTimestamp = try container.decode(Double.self, forKey: .createdAt)
        createdAt = Date(timeIntervalSince1970: unixTimestamp)
        commandCount = try container.decode(Int.self, forKey: .commandCount)
        runningCommand = try container.decodeIfPresent(String.self, forKey: .runningCommand)
        commandHistory = try container.decodeIfPresent([String].self, forKey: .commandHistory) ?? []
        attachedClientCount = try container.decodeIfPresent(Int.self, forKey: .attachedClientCount) ?? 0
    }
}

final class PtySession {
    var onOutput: ((String) -> Void)?
    var onHistoryOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onReady: ((Bool) -> Void)?

    private let sessionRef: SessionRef
    private let queue = DispatchQueue(label: "com.automicvault.vaultty.session-client")
    private var socketFd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var bridgeProcess: Process?
    private var bridgeInput: FileHandle?
    private var bridgeOutput: FileHandle?
    private var bridgeError: FileHandle?
    private var bridgeErrorOutput = Data()
    private var parserBuffer = ""
    private var treatsNextOutputAsLegacyHistory = false
    private let lifecycleLock = NSLock()
    private var isStopped = false
    private var didReportExit = false
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
        let envBlob = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\0")
        let attachLine = [
            "ATTACH",
            Self.base64(sessionRef.sessionID),
            Self.base64(workingDirectory.path),
            Self.base64(shellPath),
            Self.base64(envBlob)
        ].joined(separator: " ")

        queue.async { [weak self] in
            guard let self, !self.hasStopped() else { return }
            do {
                try self.connect()
                guard !self.hasStopped() else {
                    self.closeTransport(terminateBridge: true)
                    return
                }
                self.sendLine(attachLine)
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

    func resize(rows: UInt16, cols: UInt16) {
        sendLine("RESIZE \(rows) \(cols)")
    }

    func isCanonicalInputModeEnabled() -> Bool? {
        nil
    }

    func sendInterrupt() {
        sendLine("INTERRUPT")
    }

    func write(_ string: String, suppressEcho: Bool = false) {
        guard let data = string.data(using: .utf8) else { return }
        sendLine("INPUT \(data.base64EncodedString())")
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
        sendLine("STATE \(data.base64EncodedString())")
    }

    func stop() {
        markStopped()
        // Closing the transport is enough for sessiond to detach this client.
        // Sending DETACH synchronously can beachball the UI if the daemon is wedged.
        closeTransport(terminateBridge: true)
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
        readSource?.cancel()
        readSource = nil
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        try? bridgeOutput?.close()
        try? bridgeError?.close()
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        if terminateBridge {
            bridgeProcess?.terminate()
        }
        bridgeProcess = nil
        bridgeErrorOutput.removeAll(keepingCapacity: false)
        parserBuffer.removeAll(keepingCapacity: false)
        treatsNextOutputAsLegacyHistory = false
    }

    static func killDetachedSession(sessionID: String) throws {
        try killDetachedSession(sessionRef: .local(sessionID))
    }

    static func killDetachedSession(sessionRef: SessionRef) throws {
        let command = "KILL \(base64(sessionRef.sessionID))"
        switch sessionRef.location {
        case .local:
            try sendLocalCommandNoResponse(command, startsDaemon: false)
        case .sshHost:
            try sendCommandNoResponse(command, location: sessionRef.location)
        }
    }

    static func listSessions(location: SessionLocation = .local) throws -> [SessionMetadata] {
        let line = try sendSingleResponseCommand("LIST", location: location)
        guard let payload = line.removingPrefix("SESSIONS "),
              let data = Data(base64Encoded: payload)
        else {
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
        switch sessionRef.location {
        case .local:
            try Self.ensureDaemonIsRunning()
            let fd = try Self.connectToDaemon()
            socketFd = fd
            startReading(fd: fd)
        case .sshHost(let hostID):
            let host = try Self.sshHostRecord(id: hostID)
            let process = Self.makeSSHBridgeProcess(host: host)
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            bridgeProcess = process
            bridgeInput = inputPipe.fileHandleForWriting
            bridgeOutput = outputPipe.fileHandleForReading
            bridgeError = errorPipe.fileHandleForReading
            startReading(fileHandle: outputPipe.fileHandleForReading)
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                self?.queue.async {
                    self?.bridgeErrorOutput.append(data)
                }
            }
            process.terminationHandler = { [weak self] process in
                self?.queue.async {
                    guard let self else { return }
                    let errorText = String(data: self.bridgeErrorOutput, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus != 0, !errorText.isEmpty {
                        self.onOutput?("\nSSH bridge failed: \(errorText)\n")
                    }
                    self.reportExit(process.terminationStatus)
                }
            }
        }
    }

    private func startReading(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                self.reportExit(0)
                return
            }

            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            self.consumeProtocolText(text)
        }
        source.setCancelHandler {
        }
        source.resume()
        readSource = source
    }

    private func startReading(fileHandle: FileHandle) {
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if self?.bridgeProcess == nil {
                    self?.reportExit(0)
                }
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            self?.queue.async {
                self?.consumeProtocolText(text)
            }
        }
    }

    private func consumeProtocolText(_ text: String) {
        parserBuffer += text
        guard text.contains("\n") else { return }
        while let newline = parserBuffer.firstIndex(of: "\n") {
            let line = String(parserBuffer[..<newline])
            parserBuffer.removeSubrange(...newline)
            handleProtocolLine(line.trimmingCharacters(in: .newlines))
        }
    }

    private func handleProtocolLine(_ line: String) {
        if let payload = line.removingPrefix("OUTPUT "),
           let data = Data(base64Encoded: payload),
           let text = String(data: data, encoding: .utf8) {
            if treatsNextOutputAsLegacyHistory {
                treatsNextOutputAsLegacyHistory = false
                onHistoryOutput?(text)
            } else {
                onOutput?(text)
            }
            return
        }

        if let payload = line.removingPrefix("HISTORY "),
           let data = Data(base64Encoded: payload),
           let text = String(data: data, encoding: .utf8) {
            treatsNextOutputAsLegacyHistory = false
            onHistoryOutput?(text)
            return
        }

        if let payload = line.removingPrefix("READY ") {
            let created = payload.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            treatsNextOutputAsLegacyHistory = !created
            DispatchQueue.main.async { [weak self] in
                self?.onReady?(created)
            }
            return
        }

        if let payload = line.removingPrefix("EXIT ") {
            let status = Int32(payload.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            reportExit(status)
        }
    }

    private func sendLine(_ line: String) {
        if socketFd >= 0 {
            try? Self.writeAll(line + "\n", to: socketFd)
            return
        }
        guard let bridgeInput
        else {
            return
        }
        do {
            try Self.writeAll(line + "\n", to: bridgeInput.fileDescriptor)
        } catch {
            reportExit(-1)
        }
    }

    @discardableResult
    private static func sendSingleResponseCommand(_ command: String, location: SessionLocation) throws -> String {
        switch location {
        case .local:
            try ensureDaemonIsRunning()
            let fd = try connectToDaemon()
            defer { close(fd) }
            try writeAll(command + "\n", to: fd)
            return try readLine(from: fd)
        case .sshHost(let hostID):
            let host = try sshHostRecord(id: hostID)
            let output = try runSSHBridgeCommand(host: host, command: command)
            return String(decoding: output, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
        }
    }

    private static func sendCommandNoResponse(_ command: String, location: SessionLocation) throws {
        switch location {
        case .local:
            try sendLocalCommandNoResponse(command, startsDaemon: true)
        case .sshHost(let hostID):
            let host = try sshHostRecord(id: hostID)
            let process = makeSSHBridgeProcess(host: host, batchMode: true)
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            try writeAll(command + "\n", to: inputPipe.fileHandleForWriting.fileDescriptor)
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

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
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
