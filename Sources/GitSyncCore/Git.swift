import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Git {
    static func run(_ arguments: [String], input: Data = Data(), allowFailure: Bool = false) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let group = DispatchGroup()
        var output = Data(), error = Data()
        group.enter()
        DispatchQueue.global().async { output = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { error = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        #if canImport(Darwin)
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #elseif canImport(Glibc)
        _ = signal(SIGPIPE, SIG_IGN)
        #endif
        if !input.isEmpty { try? stdin.fileHandleForWriting.write(contentsOf: input) }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        group.wait()

        guard process.terminationStatus == 0 || allowFailure else {
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
        succeeds(["check-ref-format", ref])
    }
}
