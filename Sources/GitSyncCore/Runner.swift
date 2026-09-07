import Foundation

public enum Runner {
    public static func inspectPeer(_ configuration: Configuration) throws -> PeerInspection {
        try configuration.validate()
        let data = try runRemote(
            configuration,
            arguments: ["inspect", "--root", configuration.remoteRoot],
            failure: "Could not inspect the peer"
        )
        let inspection = try JSONDecoder().decode(PeerInspection.self, from: data)
        guard inspection.version == WireMessage.protocolVersion else {
            throw SyncError.invalidProtocol("Unsupported protocol version: \(inspection.version)")
        }
        try Validator.machine(inspection.machine)
        for name in inspection.repositories { try Validator.project(name) }
        for project in inspection.projects ?? [] { try Validator.project(project.name) }
        return inspection
    }

    public static func overlappingRepositories(_ configuration: Configuration) throws -> [String] {
        try configuration.validate()
        let local = try Repository.discover(in: configuration.expandedRoot).map(\.name)
        return overlap(local: local, remote: try inspectPeer(configuration).repositories)
    }

    public static func setPeerPlacement(_ placement: ProjectPlacement, repository: String,
                                        branch: String? = nil, configuration: Configuration) throws -> PeerProject {
        try configuration.validate()
        try Validator.project(repository)
        guard placement != .unknown else {
            throw SyncError.invalidConfiguration("Unknown is not a project placement.")
        }
        var arguments = ["project-state", "--root", configuration.remoteRoot,
                         "--repository", repository, "--placement", placement.rawValue]
        if let branch { arguments += ["--branch", branch] }
        let data = try runRemote(configuration, arguments: arguments,
                                 failure: "Could not change \(repository) on the peer")
        return try JSONDecoder().decode(PeerProject.self, from: data)
    }

    public static func projectContent(_ repository: String,
                                      configuration: Configuration) throws -> RepositoryContent {
        try configuration.validate()
        try Validator.project(repository)
        let data = try runRemote(
            configuration,
            arguments: ["project-content", "--root", configuration.remoteRoot,
                        "--repository", repository],
            failure: "Could not read \(repository) on the peer. Update Gitinuum on that host if remote browsing is unavailable"
        )
        return try JSONDecoder().decode(RepositoryContent.self, from: data)
    }

    public static func projectDiff(_ repository: String, oid: String?, staged: Bool = false,
                                   configuration: Configuration) throws -> String {
        try configuration.validate()
        try Validator.project(repository)
        if let oid { try Validator.oid(oid) }
        let data = try runRemote(
            configuration,
            arguments: ["project-diff", "--root", configuration.remoteRoot,
                        "--repository", repository] + (oid.map { ["--oid", $0] }
                            ?? ["--working-changes"] + (staged ? ["--staged"] : [])),
            failure: "Could not read the diff on the peer. Update Gitinuum on that host if remote browsing is unavailable"
        )
        return String(decoding: data, as: UTF8.self)
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
            let isBackup = configuration.remoteReceiveOnly == true
            do {
                if isBackup {
                    _ = try runRemote(
                        configuration,
                        arguments: ["check-backup"],
                        failure: "Gitinuum on \(configuration.remoteMachine ?? configuration.peer) is not accepting backups. On that Mac, choose a destination in the Backup tab and start sync"
                    )
                }
                var arguments = isBackup ? ["relay-backup"]
                    : ["daemon", "--stdio", "--root", configuration.remoteRoot]
                if !isBackup, let repositories = configuration.repositories {
                    arguments.append("--selective")
                    for repository in repositories { arguments += ["--repository", repository] }
                }
                if !isBackup, let remoteState = configuration.remoteState { arguments += ["--state", remoteState] }
                if !isBackup, configuration.syncCheckouts == true { arguments.append("--sync-checkouts") }
                let command = remoteCommand(configuration.remoteExecutable, arguments)
                process.arguments = ["-T", "--", configuration.peer, command]
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.standardError
                try process.run()
                logger("SSH connected to \(configuration.peer)")
                let session = try SyncSession(
                    root: configuration.expandedRoot, machine: configuration.machine,
                    input: output.fileHandleForReading, output: input.fileHandleForWriting,
                    stateURL: stateURL, repositories: configuration.repositories.map(Set.init),
                    peerRepositoryLocation: configuration.remoteReceiveOnly == true ? nil : configuration.remoteMachine.map {
                        PeerRepositoryLocation(machine: $0, sshTarget: configuration.peer,
                                               root: configuration.remoteRoot, displayName: configuration.remoteDisplayName)
                    },
                    isInitiator: true,
                    syncCheckouts: configuration.syncCheckouts == true,
                    logger: logger
                )
                try session.run()
            } catch { logger("reconnecting after: \(error)") }
            if process.isRunning { process.terminate() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    public static func serve(root: URL, machine: String, stateURL: URL,
                             repositories: Set<String>? = nil,
                             receiveOnly: Bool = false,
                             syncCheckouts: Bool = false,
                             catalogObserver: ((String, [String]) throws -> Void)? = nil,
                             input: FileHandle = .standardInput,
                             output: FileHandle = .standardOutput,
                             logger: @escaping (String) -> Void = { _ in }) throws {
        let session = try SyncSession(root: root, machine: machine, input: input,
                                      output: output, stateURL: stateURL,
                                      repositories: repositories, receiveOnly: receiveOnly,
                                      syncCheckouts: syncCheckouts,
                                      catalogObserver: catalogObserver, logger: logger)
        try session.run()
    }

    public static func prepareBackup(at root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SyncError.invalidConfiguration("Backup destination does not exist: \(root.path)")
        }
        let probe = root.appendingPathComponent(".git-sync-write-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: probe)
            try migrateLegacyBackups(at: root)
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain &&
             [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)) {
            var message = "Gitinuum cannot access the backup destination: \(root.path)."
            #if os(macOS)
            // TCC has no API to request a previously denied Files & Folders permission again.
            message += " Open System Settings > Privacy & Security > Files & Folders, "
                + "expand Gitinuum, and enable access to the destination "
                + "(Removable Volumes for an external drive, or Network Volumes for a network drive). "
                + "If that option is unavailable, allow Gitinuum in Privacy & Security > Full Disk Access. "
                + "Then quit and reopen Gitinuum."
            #endif
            message += " Also check that your account has read and write permission for this folder."
            throw SyncError.invalidConfiguration(message)
        }
    }

    public static func backupItems(_ configuration: Configuration) throws -> [BackupItem] {
        try backupControl(BackupControlRequest(action: .list), configuration: configuration).items ?? []
    }

    public static func archiveBackup(_ name: String, configuration: Configuration) throws {
        try Validator.project(name)
        _ = try backupControl(BackupControlRequest(action: .archive, repository: name),
                              configuration: configuration)
    }

    public static func backupContent(_ name: String, snapshotID: String,
                                     configuration: Configuration) throws -> RepositoryContent {
        try Validator.project(name)
        do {
            let data = try backupPayload(
                BackupControlRequest(action: .content, repository: name, snapshotID: snapshotID),
                configuration: configuration
            )
            return try JSONDecoder().decode(RepositoryContent.self, from: data)
        } catch {
            throw SyncError.invalidConfiguration(
                "Could not read \(name) from the backup host. Update Gitinuum on that host if remote browsing is unavailable: \(error)"
            )
        }
    }

    public static func backupDiff(_ name: String, snapshotID: String, oid: String,
                                  configuration: Configuration) throws -> String {
        try Validator.project(name)
        try Validator.oid(oid)
        do {
            return String(decoding: try backupPayload(
                BackupControlRequest(action: .diff, repository: name, snapshotID: snapshotID, oid: oid),
                configuration: configuration
            ), as: UTF8.self)
        } catch {
            throw SyncError.invalidConfiguration(
                "Could not read the commit diff from the backup host. Update Gitinuum on that host if remote browsing is unavailable: \(error)"
            )
        }
    }

    public static func replaceBackupCatalog(machine: String, repositories: [String],
                                            configuration: Configuration) throws {
        try Validator.machine(machine)
        for repository in repositories { try Validator.project(repository) }
        _ = try backupControl(
            BackupControlRequest(action: .catalog, machine: machine, repositories: repositories),
            configuration: configuration
        )
    }

    public static func restoreBackup(_ name: String, snapshot: BackupSnapshot,
                                     configuration: Configuration, to projectsRoot: URL) throws {
        try Validator.project(name)
        let bundle = projectsRoot.appendingPathComponent(".git-sync-unarchive-\(UUID()).bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let (process, input, output, error) = try startBackupControl(configuration)
        do {
            try BackupControlConnection.send(
                BackupControlRequest(action: .export, repository: name, snapshotID: snapshot.id), to: input
            )
            try input.close()
            let response = try BackupControlConnection.receive(BackupControlResponse.self, from: output).checked()
            guard let byteCount = response.byteCount else {
                throw SyncError.invalidProtocol("Backup export has no length")
            }
            guard FileManager.default.createFile(atPath: bundle.path, contents: nil) else {
                throw SyncError.invalidConfiguration("Could not create the temporary backup bundle")
            }
            let file = try FileHandle(forWritingTo: bundle)
            do {
                try BackupControlConnection.copy(byteCount, from: output, to: file)
                try file.close()
            } catch {
                try? file.close()
                throw error
            }
            try finishBackupControl(process, error: error)
            try BackupIndex.restore(name, snapshot: snapshot, from: bundle, to: projectsRoot)
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private static func migrateLegacyBackups(at root: URL) throws {
        let manager = FileManager.default
        for wrapper in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = wrapper.lastPathComponent.precomposedStringWithCanonicalMapping
            guard (try? wrapper.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  (try? Validator.project(name)) != nil,
                  try manager.contentsOfDirectory(atPath: wrapper.path) == [".git"] else { continue }
            let gitDirectory = wrapper.appendingPathComponent(".git", isDirectory: true)
            guard Git.succeeds(["-C", wrapper.path, "rev-parse", "--git-dir"]) else { continue }
            let destination = root.appendingPathComponent("\(name).git", isDirectory: true)
            guard !manager.fileExists(atPath: destination.path) else {
                throw SyncError.invalidConfiguration("Backup already exists: \(destination.path)")
            }
            _ = try Git.run(["--git-dir", gitDirectory.path, "config", "core.bare", "true"])
            try manager.moveItem(at: gitDirectory, to: destination)
            try manager.removeItem(at: wrapper)
        }
    }

    private static func runRemote(_ configuration: Configuration, arguments: [String],
                                  failure: String) throws -> Data {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "--",
            configuration.peer, remoteCommand(configuration.remoteExecutable, arguments),
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let group = DispatchGroup()
        var stdout = Data(), stderr = Data()
        group.enter()
        DispatchQueue.global().async {
            stdout = output.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            stderr = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw SyncError.invalidConfiguration(
                failure + ": " + String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return stdout
    }

    private static func startBackupControl(_ configuration: Configuration) throws
        -> (Process, FileHandle, FileHandle, Pipe) {
        try configuration.validate()
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "--",
            configuration.peer,
            remoteCommand(configuration.remoteExecutable, ["relay-backup-control"]),
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        return (process, input.fileHandleForWriting, output.fileHandleForReading, error)
    }

    private static func backupControl(_ request: BackupControlRequest,
                                      configuration: Configuration) throws -> BackupControlResponse {
        let (process, input, output, error) = try startBackupControl(configuration)
        do {
            try BackupControlConnection.send(request, to: input)
            try input.close()
            let response = try BackupControlConnection.receive(BackupControlResponse.self, from: output).checked()
            try finishBackupControl(process, error: error)
            return response
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private static func backupPayload(_ request: BackupControlRequest,
                                      configuration: Configuration) throws -> Data {
        let (process, input, output, error) = try startBackupControl(configuration)
        do {
            try BackupControlConnection.send(request, to: input)
            try input.close()
            let response = try BackupControlConnection.receive(BackupControlResponse.self, from: output).checked()
            guard let byteCount = response.byteCount else {
                throw SyncError.invalidProtocol("Backup response has no payload length")
            }
            let data = try BackupControlConnection.receivePayload(byteCount, from: output)
            try finishBackupControl(process, error: error)
            return data
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private static func finishBackupControl(_ process: Process, error: Pipe) throws {
        process.waitUntilExit()
        let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw SyncError.invalidConfiguration(
                message.isEmpty ? "Could not access backups on the backup host" : message
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func remoteCommand(_ executable: String, _ arguments: [String]) -> String {
        "exec " + ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }
}

public enum OneShot {
    @discardableResult
    public static func sync(sourceRoot: URL, destinationRoot: URL, machine: String, stateURL: URL,
                            full: Bool = false, bareDestination: Bool = false,
                            syncCheckouts: Bool = false) throws -> [String] {
        try Validator.machine(machine)
        let state = try StateStore(url: stateURL)
        let sources = try Repository.discover(in: sourceRoot)
        for source in sources {
            let destination = try Repository.ensure(name: source.name, in: destinationRoot,
                                                    bare: bareDestination)
            var known = Set(try destination.knownOIDs())
            let cleanCheckout = syncCheckouts ? source.cleanCheckoutRef() : nil
            for stored in try state.updates(machine: machine, repository: source.name,
                                            refs: source.sourceRefs(), full: full) {
                let update = RefUpdate(repository: stored.repository, sourceRef: stored.sourceRef,
                                       generation: stored.generation, oid: stored.oid,
                                       cleanCheckout: stored.sourceRef == cleanCheckout ? true : nil)
                if let oid = update.oid, !known.contains(oid) {
                    try destination.install(pack: source.pack(oid: oid, excluding: Array(known)), target: oid)
                    known.insert(oid)
                }
                try PeerRefWriter(repository: destination, peer: machine).apply(
                    sourceRef: update.sourceRef, oid: update.oid,
                    syncCheckout: syncCheckouts && update.cleanCheckout == true
                )
            }
        }
        return sources.map(\.name)
    }
}
