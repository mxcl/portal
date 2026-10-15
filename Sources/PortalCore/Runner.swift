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
        guard try inspection.namingRevision == ProjectRename.revision(ProjectRename.records(in: configuration.expandedRoot)) else {
            throw SyncError.invalidProtocol("Project naming history differs; reconcile rename journals before using this host.")
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

    public static func renameProject(_ record: ProjectRename.Record, step: ProjectRename.Step,
                                     configuration: Configuration) throws {
        let data = try JSONEncoder().encode(record)
        _ = try runRemote(configuration, arguments: ["rename-project", "--root", configuration.remoteRoot,
            "--rename-version", "2", "--step", step.rawValue, "--record", data.base64EncodedString()],
            failure: "Rename failed or its outcome is unknown on \(configuration.peer)")
    }

    public static func renameBackup(_ record: ProjectRename.Record, step: ProjectRename.Step,
                                    configuration: Configuration) throws {
        _ = try backupControl(BackupControlRequest(action: .rename, rename: record, renameStep: step),
                              configuration: configuration)
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

    public static func projectSearch(_ repository: String, query: String,
                                     configuration: Configuration) throws -> [RepositorySearchMatch] {
        try configuration.validate()
        try Validator.project(repository)
        let data = try runRemote(configuration, arguments: ["project-search", "--root", configuration.remoteRoot,
            "--repository", repository, "--query", query, "--search-version", String(RepositorySearchReply.currentVersion)],
            failure: "Search unavailable on this host; update Portal if needed")
        return try JSONDecoder().decode(RepositorySearchReply.self, from: data).checked()
    }

    public static func backupSearch(_ repository: String, snapshotID: String, query: String,
                                    configuration: Configuration) throws -> [RepositorySearchMatch] {
        try Validator.project(repository)
        let data = try backupPayload(BackupControlRequest(action: .search, repository: repository,
            snapshotID: snapshotID, query: query, searchVersion: RepositorySearchReply.currentVersion),
            configuration: configuration)
        return try JSONDecoder().decode(RepositorySearchReply.self, from: data).checked()
    }

    public static func projectContent(_ repository: String, showAuxiliaryHistory: Bool = false,
                                      configuration: Configuration) throws -> RepositoryContent {
        try configuration.validate()
        try Validator.project(repository)
        let data = try runRemote(
            configuration,
            arguments: ["project-content", "--root", configuration.remoteRoot,
                        "--repository", repository] + (showAuxiliaryHistory ? ["--show-auxiliary-history"] : []),
            failure: "Could not read \(repository) on the peer. Update Portal on that host if remote browsing is unavailable"
        )
        return try JSONDecoder().decode(RepositoryContent.self, from: data)
    }

    public static func projectStaging(_ repository: String, configuration: Configuration) throws -> RepositorySnapshot {
        try configuration.validate()
        try Validator.project(repository)
        let data = try runRemote(configuration, arguments: ["project-staging", "--root", configuration.remoteRoot,
            "--repository", repository], failure: "Could not read staging; update Portal on the peer if needed")
        return try JSONDecoder().decode(RepositorySnapshot.self, from: data)
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
            failure: "Could not read the diff on the peer. Update Portal on that host if remote browsing is unavailable"
        )
        return String(decoding: data, as: UTF8.self)
    }

    public static func overlap(local: [String], remote: [String]) -> [String] {
        let local = Set(local.map(\.precomposedStringWithCanonicalMapping))
        let remote = Set(remote.map(\.precomposedStringWithCanonicalMapping))
        return Array(local.intersection(remote)).sorted()
    }

    public static func connect(_ configuration: Configuration, stateURL: URL,
                               backupProgress: ((BackupProgress) -> Void)? = nil,
                               logger: @escaping (String) -> Void = { _ in }) throws {
        try configuration.validate()
        var configuration = configuration
        while true {
            let records = try ProjectRename.records(in: configuration.expandedRoot)
            try configuration.applyRenames(records)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            let isBackup = configuration.remoteReceiveOnly == true
            do {
                if isBackup {
                    _ = try runRemote(
                        configuration,
                        arguments: ["check-backup"],
                        failure: "Portal on \(configuration.remoteMachine ?? configuration.peer) is not accepting backups. On that Mac, choose a destination in the Backup tab and start sync"
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
                    namingRevision: configuration.appliedRenames, isInitiator: true,
                    backupProgress: isBackup ? backupProgress : nil,
                    syncCheckouts: configuration.syncCheckouts == true,
                    logger: logger
                )
                try session.run()
            } catch {
                if isBackup { backupProgress?(BackupProgress(phase: .failed, failure: String(describing: error))) }
                logger("reconnecting after: \(error)")
            }
            if process.isRunning { process.terminate() }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    public static func serve(root: URL, machine: String, stateURL: URL,
                             repositories: Set<String>? = nil,
                             receiveOnly: Bool = false,
                             syncCheckouts: Bool = false,
                             catalogObserver: ((String, [String]) throws -> Void)? = nil,
                             repositoryObserver: ((String) -> Void)? = nil,
                             input: FileHandle = .standardInput,
                             output: FileHandle = .standardOutput,
                             logger: @escaping (String) -> Void = { _ in }) throws {
        let session = try SyncSession(root: root, machine: machine, input: input,
                                      output: output, stateURL: stateURL,
                                      repositories: repositories, receiveOnly: receiveOnly,
                                      syncCheckouts: syncCheckouts,
                                      catalogObserver: catalogObserver, repositoryObserver: repositoryObserver, logger: logger)
        try session.run()
    }

    public static func prepareBackup(at root: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SyncError.invalidConfiguration("Backup destination does not exist: \(root.path)")
        }
        let probe = root.appendingPathComponent(".portal-write-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: probe)
            try migrateLegacyBackups(at: root)
        } catch let error as NSError where
            (error.domain == NSCocoaErrorDomain &&
             [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)) ||
            (error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)) {
            var message = "Portal cannot access the backup destination: \(root.path)."
            #if os(macOS)
            // TCC has no API to request a previously denied Files & Folders permission again.
            message += " Open System Settings > Privacy & Security > Files & Folders, "
                + "expand Portal, and enable access to the destination "
                + "(Removable Volumes for an external drive, or Network Volumes for a network drive). "
                + "If that option is unavailable, allow Portal in Privacy & Security > Full Disk Access. "
                + "Then quit and reopen Portal."
            #endif
            message += " Also check that your account has read and write permission for this folder."
            throw SyncError.invalidConfiguration(message)
        }
    }

    public static func retainMergedBranchLocally(_ backup: MergedBranchBackup,
                                                 socket: URL = LocalBackupTransport.controlSocketURL) throws -> MergedBranchBackup {
        let connection = try LocalBackupTransport.connect(mode: LocalBackupTransport.session, to: socket)
        defer { try? connection.close() }
        try BackupControlConnection.send(BackupControlRequest(action: .retainMergedBranch, mergedBranch: backup), to: connection)
        let response = try BackupControlConnection.receive(BackupControlResponse.self, from: connection).checked()
        guard response.mergedBranch == backup else {
            throw SyncError.invalidProtocol("Backup destination did not confirm the merged branch")
        }
        return backup
    }

    public static func retainMergedBranch(_ backup: MergedBranchBackup, configuration: Configuration) throws -> MergedBranchBackup {
        let response = try backupControl(BackupControlRequest(action: .retainMergedBranch, mergedBranch: backup), configuration: configuration)
        guard response.mergedBranch == backup else {
            throw SyncError.invalidProtocol("Backup destination did not confirm the merged branch")
        }
        return backup
    }

    public static func backupItems(_ configuration: Configuration, refresh: Bool = false) throws -> [BackupItem] {
        try backupControl(BackupControlRequest(action: .list, refresh: refresh), configuration: configuration).items ?? []
    }

    public static func archiveBackup(_ name: String, configuration: Configuration) throws {
        try Validator.project(name)
        _ = try backupControl(BackupControlRequest(action: .archive, repository: name),
                              configuration: configuration)
    }

    public static func deleteBackup(_ name: String, configuration: Configuration) throws {
        try Validator.project(name)
        _ = try backupControl(BackupControlRequest(action: .delete, repository: name),
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
                "Could not read \(name) from the backup host. Update Portal on that host if remote browsing is unavailable: \(error)"
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
                "Could not read the commit diff from the backup host. Update Portal on that host if remote browsing is unavailable: \(error)"
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
        let bundle = projectsRoot.appendingPathComponent(".portal-unarchive-\(UUID()).bundle")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try exportBackup(name, snapshot: snapshot, configuration: configuration, to: bundle)
        try BackupIndex.restore(name, snapshot: snapshot, from: bundle, to: projectsRoot)
    }

    public static func exportBackup(_ name: String, snapshot: BackupSnapshot,
                                    configuration: Configuration, to bundle: URL) throws {
        try Validator.project(name)
        let (process, input, output, error) = try startBackupControl(configuration)
        do {
            try BackupControlConnection.send(
                BackupControlRequest(action: .export, repository: name, snapshotID: snapshot.id,
                    namingRevision: try ProjectRename.revision(ProjectRename.records(in: configuration.expandedRoot))), to: input
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
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    public static func restorePeerBackup(_ name: String, snapshot: BackupSnapshot,
                                         bundle: URL, configuration: Configuration) throws -> PeerProject {
        try configuration.validate()
        try Validator.project(name)
        let packet = bundle.deletingLastPathComponent().appendingPathComponent("restore-\(UUID()).packet")
        guard FileManager.default.createFile(atPath: packet.path, contents: nil) else {
            throw SyncError.invalidConfiguration("Could not prepare the restore transfer")
        }
        defer { try? FileManager.default.removeItem(at: packet) }
        let output = try FileHandle(forWritingTo: packet)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: bundle)
        defer { try? input.close() }
        guard let count = try bundle.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw SyncError.invalidConfiguration("Could not read the backup bundle size")
        }
        try BackupControlConnection.send(ProjectRestoreRequest(name: name, snapshot: snapshot, byteCount: count), to: output)
        try BackupControlConnection.copy(count, from: input, to: output)
        try output.close()
        let transfer = try FileHandle(forReadingFrom: packet)
        defer { try? transfer.close() }
        let data = try runRemote(configuration, arguments: ["restore-project", "--root", configuration.remoteRoot],
                                 failure: "Could not restore on the peer; update Portal on that computer if needed",
                                 input: transfer)
        return try JSONDecoder().decode(PeerProject.self, from: data)
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
                                  failure: String, input: FileHandle? = nil) throws -> Data {
        let process = Process(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-T", "--",
            configuration.peer, remoteCommand(configuration.remoteExecutable, arguments),
        ]
        process.standardOutput = output
        process.standardError = error
        if let input { process.standardInput = input }
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
            var request = request
            if request.action != .rename {
                request.namingRevision = try ProjectRename.revision(ProjectRename.records(in: configuration.expandedRoot))
            }
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
            var request = request
            if request.action != .rename {
                request.namingRevision = try ProjectRename.revision(ProjectRename.records(in: configuration.expandedRoot))
            }
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

    static func remoteCommand(_ executable: String, _ arguments: [String]) -> String {
        "exec " + ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }
}

public enum OneShot {
    @discardableResult
    public static func sync(sourceRoot: URL, destinationRoot: URL, machine: String, stateURL: URL,
                            full: Bool = false, bareDestination: Bool = false,
                            syncCheckouts: Bool = false,
                            repositoryObserver: ((String) -> Void)? = nil,
                            backupProgress: ((BackupProgress) -> Void)? = nil) throws -> [String] {
        try Validator.machine(machine)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let sourceAccess = try ProjectAccess(root: sourceRoot)
        let destinationAccess = try ProjectAccess(root: destinationRoot)
        defer { withExtendedLifetime((sourceAccess, destinationAccess)) {} }
        guard try ProjectRename.revision(sourceAccess.records) == ProjectRename.revision(destinationAccess.records) else {
            throw SyncError.invalidConfiguration("Project naming histories differ; reconcile rename journals before syncing.")
        }
        let state = try StateStore(url: stateURL)
        try state.applyRenames(sourceAccess.records)
        let sources = try Repository.discover(in: sourceRoot)
        for source in sources {
            let destination = try Repository.ensure(name: source.name, in: destinationRoot,
                                                    bare: bareDestination)
            defer { repositoryObserver?(source.name) }
            var known = Set(try destination.knownOIDs())
            let updates = try state.updates(machine: machine, repository: source.name,
                                            refs: source.sourceRefs(), full: full)
            if !updates.isEmpty { backupProgress?(BackupProgress(project: source.name, phase: .transferring)) }
            let cleanCheckout = syncCheckouts && !updates.isEmpty ? source.cleanCheckoutRef() : nil
            for stored in updates {
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
            backupProgress?(BackupProgress(project: source.name, phase: .current))
        }
        return sources.map(\.name)
    }
}
