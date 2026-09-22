import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum Git {
    // Ref syntax does not change during a process's lifetime. NSCache is thread-safe
    // and evicts entries under memory pressure; misses still go through Git.
    private static let validRefs: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 16_384
        return cache
    }()

    static func run(_ arguments: [String], input: Data = Data(), allowFailure: Bool = false,
                    successStatuses: Set<Int32> = [0], environment: [String: String] = [:]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let handles = [
            stdin.fileHandleForReading, stdin.fileHandleForWriting,
            stdout.fileHandleForReading, stdout.fileHandleForWriting,
            stderr.fileHandleForReading, stderr.fileHandleForWriting,
        ]
        defer { handles.forEach { try? $0.close() } }
        try process.run()

        let group = DispatchGroup()
        var output = Data(), error = Data()
        group.enter()
        DispatchQueue.global().async { output = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { error = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        #if canImport(Darwin)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #elseif canImport(Glibc) || canImport(Musl)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        if !input.isEmpty { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        group.wait()

        guard (successStatuses.contains(process.terminationStatus)
               && (process.terminationStatus == 0 || error.isEmpty)) || allowFailure else {
            throw SyncError.command(arguments, String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    static func text(_ arguments: [String], allowFailure: Bool = false) throws -> String {
        String(decoding: try run(arguments, allowFailure: allowFailure), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func succeeds(_ arguments: [String]) -> Bool {
        (try? run(arguments)) != nil
    }

    static func checkRef(_ ref: String) -> Bool {
        let key = ref as NSString
        if validRefs.object(forKey: key) != nil { return true }
        guard succeeds(["check-ref-format", ref]) else { return false }
        validRefs.setObject(true, forKey: key)
        return true
    }
}
