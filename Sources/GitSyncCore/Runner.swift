import Foundation

public enum Runner {
    public static func overlappingRepositories(_ configuration: Configuration) throws -> [String] {
        try configuration.validate()
        let local = try Repository.discover(in: configuration.expandedRoot).map(\.name)
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "--",
            configuration.peer,
            remoteCommand(configuration.remoteExecutable, ["list", "--root", configuration.remoteRoot]),
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw SyncError.invalidConfiguration(
                "Could not inspect the peer: " + String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let remote = try JSONDecoder().decode([String].self, from: stdout)
        for name in remote { try Validator.project(name) }
        return overlap(local: local, remote: remote)
    }

    public static func overlap(local: [String], remote: [String]) -> [String] {
        let local = Set(local.map(\.precomposedStringWithCanonicalMapping))
        let remote = Set(remote.map(\.precomposedStringWithCanonicalMapping))
        return Array(local.intersection(remote)).sorted()
    }

    public static func connect(_ configuration: Configuration, stateURL: URL,
                               logger: @escaping (String) -> Void = { _ in }) throws {
        try configuration.validate()
        while true {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = remoteCommand(configuration.remoteExecutable,
                                        ["daemon", "--stdio", "--root", configuration.remoteRoot])
            process.arguments = ["-T", "--", configuration.peer, command]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()
            logger("SSH connected to \(configuration.peer)")
            do {
                let session = try SyncSession(
                    root: configuration.expandedRoot, machine: configuration.machine,
                    input: output.fileHandleForReading, output: input.fileHandleForWriting,
                    stateURL: stateURL, logger: logger
                )
                try session.run()
            } catch { logger("reconnecting after: \(error)") }
            if process.isRunning { process.terminate() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    public static func serve(root: URL, machine: String, stateURL: URL,
                             logger: @escaping (String) -> Void = { _ in }) throws {
        let session = try SyncSession(root: root, machine: machine, input: .standardInput,
                                      output: .standardOutput, stateURL: stateURL, logger: logger)
        try session.run()
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func remoteCommand(_ executable: String, _ arguments: [String]) -> String {
        "exec " + ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }
}

public enum OneShot {
    public static func sync(sourceRoot: URL, destinationRoot: URL, machine: String, stateURL: URL) throws {
        try Validator.machine(machine)
        let state = try StateStore(url: stateURL)
        for source in try Repository.discover(in: sourceRoot) {
            let destination = try Repository.ensure(name: source.name, in: destinationRoot)
            for update in try state.updates(machine: machine, repository: source.name,
                                            refs: source.sourceRefs(), full: false) {
                if let oid = update.oid {
                    try destination.install(pack: source.pack(oid: oid, excluding: destination.knownOIDs()), target: oid)
                }
                try PeerRefWriter(repository: destination, peer: machine).apply(sourceRef: update.sourceRef, oid: update.oid)
            }
        }
    }
}
