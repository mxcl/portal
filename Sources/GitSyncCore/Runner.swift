import Foundation

public enum Runner {
    public static func connect(_ configuration: Configuration, stateURL: URL,
                               logger: @escaping (String) -> Void = { _ in }) throws {
        try configuration.validate()
        while true {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let command = [
                configuration.remoteExecutable, "daemon", "--stdio", "--root",
                configuration.remoteRoot,
            ].map(shellQuote).joined(separator: " ")
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
