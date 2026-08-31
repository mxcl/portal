import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum LocalBackupTransport {
    public static let check: UInt8 = 0
    public static let session: UInt8 = 1

    public static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitSync/backup.sock")
    }

    public static func connect(mode: UInt8, to url: URL = socketURL) throws -> FileHandle {
        let descriptor = try openSocket()
        do {
            var address = try socketAddress(url.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw socketError("Could not connect to Git Sync.app") }
            try writeAll([mode], count: 1, to: descriptor)
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            systemClose(descriptor)
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
        #if canImport(Darwin)
        _ = signal(SIGPIPE, SIG_IGN)
        #elseif canImport(Glibc) || canImport(Musl)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif

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
            guard poll(&descriptors, nfds_t(descriptors.count), -1) >= 0 else {
                if errno == EINTR { continue }
                throw socketError("Backup relay failed")
            }
            if descriptors[1].revents != 0 {
                let count = systemRead(peer, &buffer, buffer.count)
                if count == 0 { return }
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw socketError("Backup relay read failed")
                }
                try writeAll(buffer, count: count, to: output)
            }
            if inputOpen, descriptors[0].revents != 0 {
                let count = systemRead(input, &buffer, buffer.count)
                if count == 0 {
                    inputOpen = false
                    _ = systemShutdown(peer, SHUT_WR)
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
                systemWrite(descriptor, $0.baseAddress!.advanced(by: offset), count - offset)
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
        _ = url.path.withCString(systemUnlink)
        descriptor = try openSocket()
        do {
            var address = try socketAddress(url.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemBind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw socketError("Could not create backup receiver") }
            guard url.path.withCString({ systemChmod($0, 0o600) }) == 0,
                  systemListen(descriptor, 1) == 0 else {
                throw socketError("Could not secure backup receiver")
            }
        } catch {
            systemClose(descriptor)
            descriptor = -1
            _ = url.path.withCString(systemUnlink)
            throw error
        }
    }

    public func accept() throws -> FileHandle {
        lock.lock(); let listening = descriptor; lock.unlock()
        guard listening >= 0 else { throw SyncError.disconnected }
        let accepted = systemAccept(listening)
        guard accepted >= 0 else { throw socketError("Backup receiver stopped") }
        return FileHandle(fileDescriptor: accepted, closeOnDealloc: true)
    }

    public func close() {
        lock.lock()
        let listening = descriptor
        descriptor = -1
        lock.unlock()
        if listening >= 0 { systemClose(listening) }
        _ = url.path.withCString(systemUnlink)
    }

    deinit { close() }
}

private func openSocket() throws -> Int32 {
    #if canImport(Darwin)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #elseif canImport(Glibc)
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw socketError("Could not open local socket") }
    return descriptor
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
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

private func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>,
                           _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.connect(descriptor, address, length)
    #elseif canImport(Glibc)
    Glibc.connect(descriptor, address, length)
    #else
    Musl.connect(descriptor, address, length)
    #endif
}

private func systemBind(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>,
                        _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.bind(descriptor, address, length)
    #elseif canImport(Glibc)
    Glibc.bind(descriptor, address, length)
    #else
    Musl.bind(descriptor, address, length)
    #endif
}

private func systemListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.listen(descriptor, backlog)
    #elseif canImport(Glibc)
    Glibc.listen(descriptor, backlog)
    #else
    Musl.listen(descriptor, backlog)
    #endif
}

private func systemAccept(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.accept(descriptor, nil, nil)
    #elseif canImport(Glibc)
    Glibc.accept(descriptor, nil, nil)
    #else
    Musl.accept(descriptor, nil, nil)
    #endif
}

private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer,
                        _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.read(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.read(descriptor, buffer, count)
    #else
    Musl.read(descriptor, buffer, count)
    #endif
}

private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer,
                         _ count: Int) -> Int {
    #if canImport(Darwin)
    Darwin.write(descriptor, buffer, count)
    #elseif canImport(Glibc)
    Glibc.write(descriptor, buffer, count)
    #else
    Musl.write(descriptor, buffer, count)
    #endif
}

private func systemShutdown(_ descriptor: Int32, _ how: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.shutdown(descriptor, how)
    #elseif canImport(Glibc)
    Glibc.shutdown(descriptor, how)
    #else
    Musl.shutdown(descriptor, how)
    #endif
}

private func systemClose(_ descriptor: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(descriptor)
    #elseif canImport(Glibc)
    _ = Glibc.close(descriptor)
    #else
    _ = Musl.close(descriptor)
    #endif
}

private func systemUnlink(_ path: UnsafePointer<CChar>) -> Int32 {
    #if canImport(Darwin)
    Darwin.unlink(path)
    #elseif canImport(Glibc)
    Glibc.unlink(path)
    #else
    Musl.unlink(path)
    #endif
}

private func systemChmod(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.chmod(path, mode)
    #elseif canImport(Glibc)
    Glibc.chmod(path, mode)
    #else
    Musl.chmod(path, mode)
    #endif
}
