import Foundation

public enum LocalBackupTransport {
    public static let check: UInt8 = 0
    public static let session: UInt8 = 1

    public static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitSync/backup.sock")
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
