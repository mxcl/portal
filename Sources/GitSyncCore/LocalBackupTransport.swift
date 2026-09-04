import Foundation

public enum LocalBackupTransport {
    public static let check: UInt8 = 0
    public static let session: UInt8 = 1

    public static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitSync/backup.sock")
    }

    public static var controlSocketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitSync/backup-control.sock")
    }
}

public enum BackupControlAction: String, Codable, Sendable {
    case list
    case archive
    case export
    case catalog
    case content
    case diff
}

public struct BackupControlRequest: Codable, Sendable {
    public let version: Int
    public let action: BackupControlAction
    public let repository: String?
    public let snapshotID: String?
    public let oid: String?
    public let machine: String?
    public let repositories: [String]?

    public init(version: Int = SyncProtocol.version, action: BackupControlAction,
                repository: String? = nil, snapshotID: String? = nil,
                oid: String? = nil, machine: String? = nil, repositories: [String]? = nil) {
        self.version = version
        self.action = action
        self.repository = repository
        self.snapshotID = snapshotID
        self.oid = oid
        self.machine = machine
        self.repositories = repositories
    }
}

public struct BackupControlResponse: Codable, Sendable {
    public let items: [BackupItem]?
    public let byteCount: Int?
    public let error: String?

    public init(items: [BackupItem]? = nil, byteCount: Int? = nil, error: String? = nil) {
        self.items = items
        self.byteCount = byteCount
        self.error = error
    }

    public func checked() throws -> BackupControlResponse {
        if let error { throw SyncError.invalidConfiguration(error) }
        return self
    }
}

public enum BackupControlConnection {
    private static let maximumMessageSize = 1_048_576

    public static func send<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumMessageSize else {
            throw SyncError.invalidProtocol("Backup control message is too large")
        }
        var length = UInt32(data.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(data)
        try handle.write(contentsOf: packet)
    }

    public static func receive<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        let header = try readExactly(4, from: handle)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= maximumMessageSize else {
            throw SyncError.invalidProtocol("Invalid backup control message length")
        }
        return try JSONDecoder().decode(type, from: readExactly(Int(length), from: handle))
    }

    public static func copy(_ count: Int, from input: FileHandle, to output: FileHandle) throws {
        guard count >= 0 else { throw SyncError.invalidProtocol("Invalid backup export length") }
        var remaining = count
        while remaining > 0 {
            guard let chunk = try input.read(upToCount: min(remaining, 64 * 1024)), !chunk.isEmpty else {
                throw SyncError.disconnected
            }
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }

    public static func receivePayload(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else { throw SyncError.invalidProtocol("Invalid payload length") }
        return try readExactly(count, from: handle)
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw SyncError.disconnected
            }
            data.append(chunk)
        }
        return data
    }
}

public enum BackupControlService {
    public static func serve(_ connection: FileHandle, root: URL, index: BackupIndex) throws {
        do {
            let request = try BackupControlConnection.receive(BackupControlRequest.self, from: connection)
            guard request.version == SyncProtocol.version else {
                throw SyncError.invalidProtocol("Unsupported backup control protocol version: \(request.version)")
            }
            switch request.action {
            case .list:
                try BackupControlConnection.send(BackupControlResponse(items: try index.items(in: root)),
                                                 to: connection)
            case .archive:
                guard let repository = request.repository else {
                    throw SyncError.invalidProtocol("Archive request is incomplete")
                }
                try index.archive(repository, in: root)
                try BackupControlConnection.send(BackupControlResponse(), to: connection)
            case .export:
                guard let repository = request.repository, let snapshotID = request.snapshotID else {
                    throw SyncError.invalidProtocol("Export request is incomplete")
                }
                let bundle = FileManager.default.temporaryDirectory
                    .appendingPathComponent("git-sync-export-\(UUID()).bundle")
                defer { try? FileManager.default.removeItem(at: bundle) }
                try BackupIndex.exportBundle(repository, snapshotID: snapshotID,
                                             from: root, to: bundle)
                let size = try bundle.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try BackupControlConnection.send(BackupControlResponse(byteCount: size), to: connection)
                let input = try FileHandle(forReadingFrom: bundle)
                defer { try? input.close() }
                try BackupControlConnection.copy(size, from: input, to: connection)
            case .catalog:
                guard let machine = request.machine, let repositories = request.repositories else {
                    throw SyncError.invalidProtocol("Catalog request is incomplete")
                }
                try index.replaceCatalog(machine: machine, repositories: repositories)
                try BackupControlConnection.send(BackupControlResponse(), to: connection)
            case .content:
                guard let repository = request.repository, let snapshotID = request.snapshotID else {
                    throw SyncError.invalidProtocol("Content request is incomplete")
                }
                let data = try JSONEncoder().encode(
                    BackupIndex.content(repository, snapshotID: snapshotID, from: root)
                )
                try BackupControlConnection.send(BackupControlResponse(byteCount: data.count), to: connection)
                try connection.write(contentsOf: data)
            case .diff:
                guard let repository = request.repository, let snapshotID = request.snapshotID,
                      let oid = request.oid else {
                    throw SyncError.invalidProtocol("Diff request is incomplete")
                }
                let data = Data(try BackupIndex.diff(repository, snapshotID: snapshotID,
                                                     oid: oid, from: root).utf8)
                try BackupControlConnection.send(BackupControlResponse(byteCount: data.count), to: connection)
                try connection.write(contentsOf: data)
            }
        } catch {
            try BackupControlConnection.send(BackupControlResponse(error: String(describing: error)),
                                             to: connection)
        }
    }
}

#if canImport(Darwin)
import Darwin

extension LocalBackupTransport {
    public static func connect(mode: UInt8, to url: URL = socketURL) throws -> FileHandle {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("Could not open local socket") }
        do {
            var address = try socketAddress(url.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw socketError("Could not connect to Git Sync.app") }
            try writeAll([mode], count: 1, to: descriptor)
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public static func mode(from handle: FileHandle) throws -> UInt8 {
        guard let data = try handle.read(upToCount: 1), let mode = data.first else {
            throw SyncError.disconnected
        }
        return mode
    }

    public static func relayStandardIO(to url: URL = socketURL) throws {
        let socket = try connect(mode: session, to: url)
        defer { try? socket.close() }
        _ = signal(SIGPIPE, SIG_IGN)

        let input = FileHandle.standardInput.fileDescriptor
        let output = FileHandle.standardOutput.fileDescriptor
        let peer = socket.fileDescriptor
        var inputOpen = true
        var descriptors = [
            pollfd(fd: input, events: Int16(POLLIN | POLLHUP), revents: 0),
            pollfd(fd: peer, events: Int16(POLLIN | POLLHUP), revents: 0),
        ]
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            descriptors[0].events = inputOpen ? Int16(POLLIN | POLLHUP) : 0
            descriptors[0].revents = 0
            descriptors[1].revents = 0
            guard Darwin.poll(&descriptors, nfds_t(descriptors.count), -1) >= 0 else {
                if errno == EINTR { continue }
                throw socketError("Backup relay failed")
            }
            if descriptors[1].revents != 0 {
                let count = Darwin.read(peer, &buffer, buffer.count)
                if count == 0 { return }
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw socketError("Backup relay read failed")
                }
                try writeAll(buffer, count: count, to: output)
            }
            if inputOpen, descriptors[0].revents != 0 {
                let count = Darwin.read(input, &buffer, buffer.count)
                if count == 0 {
                    inputOpen = false
                    _ = Darwin.shutdown(peer, SHUT_WR)
                } else if count > 0 {
                    try writeAll(buffer, count: count, to: peer)
                } else if errno != EINTR {
                    throw socketError("Backup relay read failed")
                }
            }
        }
    }

    private static func writeAll(_ buffer: [UInt8], count: Int, to descriptor: Int32) throws {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            guard written > 0 else {
                if written < 0, errno == EINTR { continue }
                throw socketError("Backup relay write failed")
            }
            offset += written
        }
    }
}

public final class LocalBackupListener: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var descriptor: Int32

    public init(url: URL = LocalBackupTransport.socketURL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        Darwin.unlink(url.path)
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("Could not open local socket") }
        do {
            var address = try socketAddress(url.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw socketError("Could not create backup receiver") }
            guard Darwin.chmod(url.path, 0o600) == 0, Darwin.listen(descriptor, 1) == 0 else {
                throw socketError("Could not secure backup receiver")
            }
        } catch {
            Darwin.close(descriptor)
            descriptor = -1
            Darwin.unlink(url.path)
            throw error
        }
    }

    public func accept() throws -> FileHandle {
        lock.lock(); let listening = descriptor; lock.unlock()
        guard listening >= 0 else { throw SyncError.disconnected }
        let accepted = Darwin.accept(listening, nil, nil)
        guard accepted >= 0 else { throw socketError("Backup receiver stopped") }
        return FileHandle(fileDescriptor: accepted, closeOnDealloc: true)
    }

    public func close() {
        lock.lock()
        let listening = descriptor
        descriptor = -1
        lock.unlock()
        if listening >= 0 {
            _ = Darwin.shutdown(listening, SHUT_RDWR)
            Darwin.close(listening)
        }
        Darwin.unlink(url.path)
    }

    deinit { close() }
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw SyncError.invalidConfiguration("Backup receiver socket path is too long: \(path)")
    }
    path.withCString { source in
        withUnsafeMutablePointer(to: &address.sun_path.0) {
            _ = strncpy($0, source, bytes.count)
        }
    }
    return address
}

private func socketError(_ context: String) -> SyncError {
    SyncError.invalidConfiguration("\(context): \(String(cString: strerror(errno)))")
}

#else

extension LocalBackupTransport {
    public static func connect(mode: UInt8, to url: URL = socketURL) throws -> FileHandle {
        throw SyncError.invalidConfiguration("App-owned backup receiving requires macOS")
    }

    public static func mode(from handle: FileHandle) throws -> UInt8 {
        throw SyncError.invalidConfiguration("App-owned backup receiving requires macOS")
    }

    public static func relayStandardIO(to url: URL = socketURL) throws {
        throw SyncError.invalidConfiguration("App-owned backup receiving requires macOS")
    }
}

public final class LocalBackupListener: @unchecked Sendable {
    public init(url: URL = LocalBackupTransport.socketURL) throws {
        throw SyncError.invalidConfiguration("App-owned backup receiving requires macOS")
    }
    public func accept() throws -> FileHandle { throw SyncError.disconnected }
    public func close() {}
}

#endif
