#if os(macOS)
import Combine
import Darwin
import Foundation
import GitSyncCore

public enum EngineControlProtocol {
    public static let version = 1
    public static let changedNotification = Notification.Name("dev.mxcl.git-sync.engine-changed")
    public static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitSync/engine-control.sock")
    }
}

public enum EngineCommand: Codable, Sendable {
    case snapshot
    case setRoot(root: String, machine: String)
    case pause
    case resume
    case refresh
    case addHost(peer: String, root: String, executable: String, allowNameCollisions: Bool)
    case renameHost(id: UUID, name: String)
    case removeHost(UUID)
    case setBackupDestination(String)
    case chooseBackupHost(UUID)
    case setSyncCheckouts(Bool)
    case setPlacement(ProjectPlacement, project: String, hostID: UUID?, branch: String?)
    case restoreBackup(BackupItem, BackupSnapshot)
    case prepareForTermination
}

public struct EngineRequest: Codable, Sendable {
    public let version: Int
    public let command: EngineCommand

    public init(version: Int = EngineControlProtocol.version, command: EngineCommand) {
        self.version = version
        self.command = command
    }
}

public struct EngineSnapshot: Codable, Sendable {
    public let configuration: AppConfiguration
    public let status: String
    public let error: String?
    public let isChecking: Bool
    public let isRunning: Bool
    public let isPaused: Bool
    public let logs: [String]
    public let backupItems: [BackupItem]
    public let backupError: String?
    public let restoringBackup: String?
    public let placementInProgress: String?
    public let localProjects: [String: PeerProject]
    public let remoteProjects: [UUID: [String: PeerProject]]
}

public struct EngineReply: Codable, Sendable {
    public let snapshot: EngineSnapshot?
    public let nameCollisions: [String]
    public let error: String?

    public init(snapshot: EngineSnapshot? = nil, nameCollisions: [String] = [], error: String? = nil) {
        self.snapshot = snapshot
        self.nameCollisions = nameCollisions
        self.error = error
    }

    public func checked() throws -> EngineReply {
        if let error { throw EngineControlError.message(error) }
        return self
    }
}

public enum EngineControlError: Error, LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}

@MainActor
public final class EngineModel: ObservableObject {
    @Published public private(set) var configuration: AppConfiguration
    @Published public private(set) var status = "Not configured"
    @Published public private(set) var error: String?
    @Published public private(set) var isChecking = false
    @Published public private(set) var isRunning = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var backupItems: [BackupItem] = []
    @Published public private(set) var backupError: String?
    @Published public private(set) var restoringBackup: String?
    @Published public private(set) var placementInProgress: String?
    @Published public private(set) var localProjects: [String: PeerProject] = [:]
    @Published public private(set) var remoteProjects: [UUID: [String: PeerProject]] = [:]

    private let executableURL: URL
    private let label = "dev.mxcl.git-sync"
    private let support: URL
    private var configURL: URL { support.appendingPathComponent("config-v2.json") }
    private var previousConfigURL: URL { support.appendingPathComponent("config.json") }
    private var legacyConfigURL: URL { support.appendingPathComponent("config-v1-legacy.json") }
    private var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private var syncProcesses: [UUID: Process] = [:]
    private var backupReceiver: BackupReceiver?
    private var localBackup: LocalBackup?
    private var backupIndex: BackupIndex?
    private var backupIndexID: UUID?
    private var backupRefreshGeneration = 0
    private var discoveryTask: Task<Void, Never>?

    init(executableURL: URL, configuration: AppConfiguration, support: URL) {
        self.executableURL = executableURL
        self.configuration = configuration
        self.support = support
    }

    public convenience init(executableURL: URL) {
        self.init(executableURL: executableURL,
                  configuration: AppConfiguration(root: "", machine: Configuration.defaultMachine),
                  support: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("GitSync", isDirectory: true))
        removeLegacyAgent()
        preserveLegacyConfiguration()
        if let data = try? Data(contentsOf: configURL) {
            if let saved = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
                configuration = saved
            } else if let legacy = try? JSONDecoder().decode(Configuration.self, from: data) {
                configuration.root = legacy.root
                configuration.machine = legacy.machine
            }
        }
        refreshLocalNow()
        do { try loadBackupIndex() } catch { fail(error) }
        if !configuration.hosts.isEmpty {
            isChecking = true
            status = "Checking Hosts"
            Task { await refreshHostIdentities(startAfter: true) }
        } else if isConfigured {
            do { try launchAll() } catch { fail(error) }
        } else {
            status = configuration.backupDestination == nil ? "Add a host" : "Stopped"
        }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDiscovery()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    public var isConfigured: Bool { !configuration.root.isEmpty }

    private func preserveLegacyConfiguration() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: configURL.path),
              manager.fileExists(atPath: previousConfigURL.path),
              !manager.fileExists(atPath: legacyConfigURL.path) else { return }
        try? manager.createDirectory(at: support, withIntermediateDirectories: true)
        try? manager.copyItem(at: previousConfigURL, to: legacyConfigURL)
    }

    public var menuLogs: [String] {
        countedEvents(logs).suffix(8).reversed().map { event in
            let count = event.count > 1 ? " ×\(event.count)" : ""
            let limit = 90 - count.count
            let message = event.message.count > limit ? String(event.message.prefix(limit - 1)) + "…" : event.message
            return message + count
        }
    }

    public func snapshot() -> EngineSnapshot {
        EngineSnapshot(configuration: configuration, status: status, error: error,
                       isChecking: isChecking, isRunning: isRunning, isPaused: isPaused,
                       logs: logs, backupItems: backupItems, backupError: backupError,
                       restoringBackup: restoringBackup, placementInProgress: placementInProgress,
                       localProjects: localProjects, remoteProjects: remoteProjects)
    }

    public func handle(_ command: EngineCommand) async -> EngineReply {
        do {
            var collisions: [String] = []
            switch command {
            case .snapshot:
                break
            case let .setRoot(root, machine):
                guard configuration.root.isEmpty else {
                    throw EngineControlError.message("The projects folder cannot be changed.")
                }
                let candidate = Configuration(root: root, machine: machine, peer: "local", remoteRoot: root)
                try candidate.validate()
                configuration.root = root
                configuration.machine = machine
                refreshLocal()
            case .pause:
                pause()
            case .resume:
                resume()
            case .refresh:
                refreshLocal()
            case let .addHost(peer, root, executable, allowNameCollisions):
                collisions = try await addHost(peer: peer, root: root, executable: executable,
                                               allowNameCollisions: allowNameCollisions)
            case let .renameHost(id, name):
                try renameHost(id: id, name: name)
            case .removeHost(let id):
                try removeHost(id)
            case .setBackupDestination(let root):
                try setBackupDestination(root)
            case .chooseBackupHost(let id):
                chooseBackupHost(id)
            case .setSyncCheckouts(let enabled):
                setSyncCheckouts(enabled)
            case let .setPlacement(placement, project, hostID, branch):
                setPlacement(placement, project: project, hostID: hostID, branch: branch)
            case let .restoreBackup(item, backup):
                restoreBackup(item, snapshot: backup)
            case .prepareForTermination:
                shutdown()
            }
            return EngineReply(snapshot: snapshot(), nameCollisions: collisions)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return EngineReply(snapshot: snapshot(), error: message)
        }
    }

    public func shutdown() {
        discoveryTask?.cancel()
        discoveryTask = nil
        stopProcesses()
        status = "Stopped"
    }

    public func setRoot(_ root: String) {
        guard configuration.root.isEmpty else { return }
        configuration.root = root
        refreshLocal()
    }

    public func pause() {
        guard isConfigured else { return }
        stopProcesses()
        isPaused = true
        status = "Paused"
    }

    public func resume() {
        guard isConfigured else { return }
        isPaused = false
        do { try launchAll() } catch { fail(error) }
    }

    public func placement(of project: String, on hostID: UUID?) -> ProjectPlacement {
        if let hostID { return remoteProjects[hostID]?[project]?.placement ?? .unknown }
        guard let folder = configuration.folders.first(where: { $0.name == project }), folder.availableLocally else {
            return .notPresent
        }
        return localProjects[project]?.placement ?? .unknown
    }

    public func setPlacement(_ placement: ProjectPlacement, project: String, hostID: UUID?, branch: String? = nil) {
        guard placementInProgress == nil else { return }
        if placement == .notPresent {
            let otherPlacements = ([nil] + configuration.hosts.map { Optional($0.id) })
                .filter { $0 != hostID }.map { self.placement(of: project, on: $0) }
            let hasOtherCopy = otherPlacements.contains(.checkedOut) || otherPlacements.contains(.mirrored)
            let hasBackup = backupItems.first(where: { $0.name == project })?.snapshots.isEmpty == false
            guard hasOtherCopy || hasBackup else {
                error = "A current backup is required before removing the last host copy."
                return
            }
        }
        placementInProgress = hostID?.uuidString ?? "local"
        error = nil
        let root = expandedRoot
        let host = hostID.flatMap { id in configuration.hosts.first(where: { $0.id == id }) }
        let connection = host.map {
            Configuration(root: configuration.root, machine: configuration.machine,
                          peer: $0.peer, remoteRoot: $0.root, remoteExecutable: $0.executable,
                          repositories: [], remoteMachine: $0.machine)
        }
        stopHostProcess(hostID)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    if let connection {
                        return try Runner.setPeerPlacement(placement, repository: project,
                                                           branch: branch, configuration: connection)
                    }
                    let repository = try Repository.setPlacement(name: project, in: root, to: placement,
                                                                  branch: branch)
                    return PeerProject(name: project, placement: placement == .notPresent ? .notPresent : repository.placement,
                                       defaultBranch: placement == .notPresent ? nil : repository.defaultBranch)
                }.value
                updatePlacement(result, hostID: hostID)
                try save()
                if placement == .notPresent {
                    let index = backupIndex
                    let backup = try backupControlConfiguration()
                    let machine = configuration.machine
                    try await Task.detached(priority: .userInitiated) {
                        guard index != nil || backup != nil else { return }
                        let names: [String]
                        let sourceMachine: String
                        if let connection {
                            let inspection = try Runner.inspectPeer(connection)
                            names = inspection.repositories
                            sourceMachine = inspection.machine
                        } else {
                            names = try Repository.discover(in: root).map(\.name)
                            sourceMachine = machine
                        }
                        if let index { try index.replaceCatalog(machine: sourceMachine, repositories: names) }
                        else if let backup {
                            try Runner.replaceBackupCatalog(machine: sourceMachine, repositories: names,
                                                            configuration: backup)
                        }
                    }.value
                    await refreshBackupItems()?.value
                }
                placementInProgress = nil
                try startHostProcess(hostID)
            } catch {
                placementInProgress = nil
                try? startHostProcess(hostID)
                fail(error)
            }
        }
    }


    public func setBackupDestination(_ root: String) throws {
        guard configuration.backupDestination == nil, configuration.backup == nil else { return }
        configuration.backupDestination = BackupDestinationConfiguration(root: root)
        try save()
        try loadBackupIndex()
        if isRunning { restartIfRunning() }
        else if isConfigured && !isPaused { try launchAll() }
    }

    public func restoreBackup(_ item: BackupItem, snapshot: BackupSnapshot) {
        do {
            let backupRoot = try configuration.validatedBackupDestination()
            let index = backupIndex
            let remote = backupRoot == nil ? try backupControlConfiguration() : nil
            guard (backupRoot != nil && index != nil) || remote != nil else { return }
            let projectsRoot = expandedRoot
            let machine = configuration.machine
            restoringBackup = item.name
            status = "Bringing \(item.name) to this Mac"
            Task {
                do {
                    let names = try await Task.detached(priority: .userInitiated) {
                        if let backupRoot {
                            try BackupIndex.restore(item.name, snapshotID: snapshot.id,
                                                    from: backupRoot, to: projectsRoot)
                        } else if let remote {
                            try Runner.restoreBackup(item.name, snapshot: snapshot,
                                                     configuration: remote, to: projectsRoot)
                        }
                        let names = try Repository.discover(in: projectsRoot).map(\.name)
                        if let index { try index.replaceCatalog(machine: machine, repositories: names) }
                        else if let remote {
                            try Runner.replaceBackupCatalog(machine: machine, repositories: names,
                                                            configuration: remote)
                        }
                        return names
                    }.value
                    try configuration.discoverLocal(names)
                    try save()
                    restartIfRunning()
                    restoringBackup = nil
                    status = isRunning ? "Standing By" : "Stopped"
                    refreshBackupItems()
                    appendLog("Brought \(item.name) to this Mac from \(snapshot.machine)")
                } catch {
                    restoringBackup = nil
                    fail(error)
                }
            }
        } catch { fail(error) }
    }


    public func refreshLocal() {
        guard !configuration.root.isEmpty else { return }
        isChecking = true
        error = nil
        Task {
            do {
                try await discoverLocalProjects(priority: .userInitiated)
                isChecking = false
                error = nil
                try save()
                restartIfRunning()
            } catch { fail(error) }
        }
    }


    public func addHost(peer: String, root: String, executable: String,
                        allowNameCollisions: Bool) async throws -> [String] {
        guard !isChecking else { throw EngineControlError.message("Git Sync is already checking hosts.") }
        let probe = Configuration(root: configuration.root, machine: configuration.machine,
                                  peer: peer, remoteRoot: root, remoteExecutable: executable,
                                  repositories: [])
        try probe.validate()
        isChecking = true
        status = "Checking Host"
        defer { isChecking = false }
        let inspection = try await Task.detached(priority: .userInitiated) {
            try Runner.inspectPeer(probe)
        }.value
        var candidate = configuration
        let host = SyncHost(machine: inspection.machine, peer: probe.peer,
                            root: probe.remoteRoot, executable: probe.remoteExecutable)
        let collisions = try candidate.addHost(host, repositories: inspection.repositories)
        if !collisions.isEmpty && !allowNameCollisions {
            status = "Confirmation required"
            return collisions
        }
        try apply(candidate)
        recordInspection(inspection, hostID: host.id, knownProjects: candidate.folders.map(\.name))
        status = isRunning ? "Standing By" : "Stopped"
        return []
    }

    public func renameHost(id: UUID, name: String) throws {
        try configuration.renameHost(id, name: name)
        try save()
    }

    public func removeHost(_ id: UUID) throws {
        if configuration.backup?.hostID == id {
            throw EngineControlError.message("This host owns the backup destination and cannot be removed.")
        }
        let soleProjects = configuration.folders.filter {
            !$0.availableLocally && $0.availableHosts == [id]
        }.map(\.name)
        if !soleProjects.isEmpty {
            throw EngineControlError.message(
                "This host is the only active location for: \(soleProjects.joined(separator: ", "))."
            )
        }
        configuration.removeHost(id)
        remoteProjects.removeValue(forKey: id)
        try save()
        restartIfRunning()
        if !isRunning {
            status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped"
        }
    }

    public func chooseBackupHost(_ hostID: UUID) {
        guard configuration.backup == nil, configuration.backupDestination == nil else { return }
        configuration.backup = BackupConfiguration(hostID: hostID)
        configurationChanged()
        refreshBackupItems()
    }

    public func setSyncCheckouts(_ enabled: Bool) {
        configuration.syncCheckouts = enabled
        configurationChanged()
    }

    private func apply(_ candidate: AppConfiguration) throws {
        configuration = candidate
        error = nil
        try save()
        if !isPaused {
            stopProcesses()
            try launchAll()
        }
    }

    private func configurationChanged() {
        do {
            try save()
            if isRunning { restartIfRunning() }
            else if isConfigured && !isPaused { try launchAll() }
        } catch { fail(error) }
    }

    private func save() throws {
        guard FileManager.default.fileExists(atPath: expandedRoot.path) else {
            throw SyncError.invalidConfiguration("Source folder does not exist: \(configuration.root)")
        }
        _ = try configuration.backupHost()
        _ = try configuration.validatedBackupDestination()
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: configURL, options: .atomic)
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stopProcesses()
        do { try launchAll() } catch { fail(error) }
    }

    private func updatePlacement(_ project: PeerProject, hostID: UUID?) {
        if let hostID {
            remoteProjects[hostID, default: [:]][project.name] = project
        } else {
            localProjects[project.name] = project
        }
        if !configuration.folders.contains(where: { $0.name == project.name }) {
            configuration.folders.append(SyncFolder(name: project.name))
        }
        guard let index = configuration.folders.firstIndex(where: { $0.name == project.name }) else { return }
        let present = project.placement == .checkedOut || project.placement == .mirrored
        if let hostID {
            if present {
                configuration.folders[index].hosts.insert(hostID)
                configuration.folders[index].availableHosts.insert(hostID)
            } else {
                configuration.folders[index].hosts.remove(hostID)
                configuration.folders[index].availableHosts.remove(hostID)
            }
        } else {
            configuration.folders[index].isLocal = present
            configuration.folders[index].availableLocally = present
        }
        configuration.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func stopHostProcess(_ hostID: UUID?) {
        guard let hostID else { stopProcesses(); return }
        guard let process = syncProcesses.removeValue(forKey: hostID) else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }

    private func startHostProcess(_ hostID: UUID?) throws {
        guard !isPaused else { return }
        guard let hostID else { try launchAll(); return }
        guard let host = configuration.hosts.first(where: { $0.id == hostID }) else { return }
        let repositories = configuration.repositories(for: host.id)
        guard !repositories.isEmpty else { return }
        let helper = executableURL
        let connection = Configuration(root: configuration.root, machine: configuration.machine,
                                       peer: host.peer, remoteRoot: host.root,
                                       remoteExecutable: host.executable, repositories: repositories,
                                       remoteMachine: host.machine,
                                       syncCheckouts: configuration.syncCheckouts)
        try connection.validate()
        try launch(connection, id: host.id, name: host.name, helper: helper)
        isRunning = true
        status = "Standing By"
    }

    private func launchAll() throws {
        guard syncProcesses.isEmpty, backupReceiver == nil, localBackup == nil else { return }
        let helper = executableURL
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do {
            if let destination = try configuration.validatedBackupDestination(),
               let destinationConfiguration = configuration.backupDestination {
                try Runner.prepareBackup(at: destination)
                let index = try backupIndex(for: destinationConfiguration.id)
                let catalogChanged = { [weak self] in
                    _ = Task { @MainActor [weak self] in self?.refreshBackupItems() }
                }
                let receiver = try BackupReceiver(
                    root: destination, machine: configuration.machine,
                    stateURL: support.appendingPathComponent(
                        "backup-receiver-\(destinationConfiguration.id.uuidString).json"
                    ),
                    index: index, onCatalog: catalogChanged,
                    logger: { [weak self] message in
                        Task { @MainActor [weak self] in self?.appendLog("Backup receiver: \(message)") }
                    },
                    onStopped: { [weak self] id in
                        Task { @MainActor [weak self] in
                            guard let self, self.backupReceiver?.id == id else { return }
                            self.backupReceiver = nil
                            self.isRunning = !self.syncProcesses.isEmpty || self.localBackup != nil
                            if !self.isRunning { self.status = "Stopped" }
                        }
                    }
                )
                receiver.start()
                backupReceiver = receiver
                appendLog("Accepting backups into \(destination.path)")

                let backup = LocalBackup(
                    source: expandedRoot, destination: destination, machine: configuration.machine,
                    stateURL: support.appendingPathComponent(
                        "backup-source-\(destinationConfiguration.id.uuidString).json"
                    ),
                    index: index, onCatalog: catalogChanged,
                    logger: { [weak self] message in
                        Task { @MainActor [weak self] in self?.appendLog("Local backup: \(message)") }
                    },
                    onStopped: { [weak self] id in
                        Task { @MainActor [weak self] in
                            guard let self, self.localBackup?.id == id else { return }
                            self.localBackup = nil
                            self.isRunning = !self.syncProcesses.isEmpty || self.backupReceiver != nil
                            if !self.isRunning { self.status = "Stopped" }
                        }
                    }
                )
                backup.start()
                localBackup = backup
                appendLog("Backing up this Mac into \(destination.path)")
            }
            for host in configuration.hosts {
                let repositories = configuration.repositories(for: host.id)
                guard !repositories.isEmpty else { continue }
                let connection = Configuration(root: configuration.root, machine: configuration.machine,
                                               peer: host.peer, remoteRoot: host.root,
                                               remoteExecutable: host.executable, repositories: repositories,
                                               remoteMachine: host.machine,
                                               syncCheckouts: configuration.syncCheckouts)
                try connection.validate()
                try launch(connection, id: host.id, name: host.name, helper: helper)
            }
            if let backup = configuration.backup, let host = try configuration.backupHost() {
                let connection = Configuration(
                    root: configuration.root, machine: configuration.machine,
                    peer: host.peer, remoteRoot: "", remoteExecutable: host.executable,
                    remoteMachine: host.machine,
                    remoteReceiveOnly: true
                )
                try connection.validate()
                try launch(connection, id: backup.id, name: "Backup on \(host.name)", helper: helper)
            }
        } catch {
            stopProcesses()
            throw error
        }
        isRunning = !syncProcesses.isEmpty || backupReceiver != nil || localBackup != nil
        error = nil
        status = isRunning ? "Standing By" : "No folders selected"
    }

    private func launch(_ configuration: Configuration, id: UUID, name: String, helper: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let connectionURL = support.appendingPathComponent("connection-\(id.uuidString).json")
        let stateURL = support.appendingPathComponent("state-\(id.uuidString).json")
        try encoder.encode(configuration).write(to: connectionURL, options: .atomic)

        let process = Process(), output = Pipe()
        process.executableURL = helper
        process.arguments = ["run", "--config", connectionURL.path, "--state", stateURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.appendLogs(data, host: name) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.syncProcesses[id] === process else { return }
                output.fileHandleForReading.readabilityHandler = nil
                self.syncProcesses.removeValue(forKey: id)
                self.isRunning = !self.syncProcesses.isEmpty || self.backupReceiver != nil || self.localBackup != nil
                if process.terminationStatus != 0 {
                    self.appendLog("\(name): git-sync exited with status \(process.terminationStatus)")
                }
                if !self.isRunning { self.status = "Stopped" }
            }
        }
        try process.run()
        syncProcesses[id] = process
        appendLog("Started \(name)")
    }

    private func appendLogs(_ data: Data, host: String) {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.hasPrefix("[git-sync] ") ? $0.dropFirst(11) : $0[...] }
            .forEach { line in
                appendLog(line.contains(" → ") || line.contains(" ← ") ? String(line) : "\(host): \(line)")
            }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

    private func stopProcesses() {
        localBackup?.stop()
        localBackup = nil
        backupReceiver?.stop()
        backupReceiver = nil
        let processes = Array(syncProcesses.values)
        syncProcesses.removeAll()
        for process in processes {
            process.terminationHandler = nil
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        isRunning = false
    }

    private func fail(_ error: Error) {
        isChecking = false
        restoringBackup = nil
        self.error = String(describing: error)
        status = isRunning ? "Standing By" : "Stopped"
        appendLog("Error: \(error)")
    }

    private func refreshLocalNow() {
        guard !configuration.root.isEmpty else { return }
        let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
        if let names = try? Repository.discover(in: root).map(\.name) {
            try? configuration.discoverLocal(names)
            localProjects = Dictionary(uniqueKeysWithValues: names.map {
                ($0, PeerProject(name: $0, placement: .unknown))
            })
        }
    }

    private func discoverLocalProjects(priority: TaskPriority) async throws {
        let root = expandedRoot
        let projects = try await Task.detached(priority: priority) {
            try Repository.discover(in: root).map {
                PeerProject(name: $0.name, placement: $0.placement, defaultBranch: $0.defaultBranch)
            }
        }.value
        try configuration.discoverLocal(projects.map(\.name))
        localProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0) })
    }

    private func refreshHostIdentities(startAfter: Bool) async {
        for host in configuration.hosts {
            let probe = Configuration(root: configuration.root, machine: configuration.machine,
                                      peer: host.peer, remoteRoot: host.root,
                                      remoteExecutable: host.executable, repositories: [])
            if let inspection = try? await Task.detached(priority: .userInitiated, operation: {
                try Runner.inspectPeer(probe)
            }).value {
                try? configuration.updateHostIdentity(host.id, machine: inspection.machine)
                recordInspection(inspection, hostID: host.id,
                                 knownProjects: configuration.folders.map(\.name))
            }
        }
        try? await discoverLocalProjects(priority: .utility)
        isChecking = false
        try? save()
        if startAfter {
            do { try launchAll() } catch { fail(error) }
        } else {
            status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped"
        }
    }

    private func refreshDiscovery() async {
        guard isConfigured, !isChecking, placementInProgress == nil else { return }
        let original = configuration
        try? await discoverLocalProjects(priority: .utility)
        for host in configuration.hosts {
            let probe = Configuration(root: configuration.root, machine: configuration.machine,
                                      peer: host.peer, remoteRoot: host.root,
                                      remoteExecutable: host.executable, repositories: [])
            if let inspection = try? await Task.detached(priority: .utility, operation: {
                try Runner.inspectPeer(probe)
            }).value {
                recordInspection(inspection, hostID: host.id,
                                 knownProjects: configuration.folders.map(\.name))
            }
        }
        if configuration != original {
            try? save()
            restartIfRunning()
        }
        refreshBackupItems()
    }

    private func recordInspection(_ inspection: PeerInspection, hostID: UUID,
                                  knownProjects: [String]) {
        let reported = inspection.projects ?? inspection.repositories.map {
            PeerProject(name: $0, placement: .unknown)
        }
        var states = Dictionary(uniqueKeysWithValues: reported.map { ($0.name, $0) })
        for name in knownProjects where states[name] == nil {
            states[name] = PeerProject(name: name, placement: .notPresent)
        }
        remoteProjects[hostID] = states
        let present = Set(inspection.repositories)
        for index in configuration.folders.indices {
            if present.contains(configuration.folders[index].name) {
                configuration.folders[index].hosts.insert(hostID)
                configuration.folders[index].availableHosts.insert(hostID)
            } else {
                configuration.folders[index].hosts.remove(hostID)
                configuration.folders[index].availableHosts.remove(hostID)
            }
        }
        for project in reported where !configuration.folders.contains(where: { $0.name == project.name }) {
            configuration.folders.append(SyncFolder(name: project.name, hosts: [hostID], availableHosts: [hostID]))
        }
        configuration.folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var expandedRoot: URL {
        URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath).standardizedFileURL
    }

    func loadBackupIndex() throws {
        guard let destination = configuration.backupDestination else {
            backupIndex = nil
            backupIndexID = nil
            refreshBackupItems()
            return
        }
        _ = try backupIndex(for: destination.id)
        refreshBackupItems()
    }

    private func backupIndex(for id: UUID) throws -> BackupIndex {
        if backupIndexID == id, let backupIndex { return backupIndex }
        let index = try BackupIndex(url: support.appendingPathComponent("backup-index-\(id.uuidString).json"))
        backupIndex = index
        backupIndexID = id
        return index
    }

    @discardableResult
    private func refreshBackupItems() -> Task<Void, Never>? {
        let index = backupIndex
        let root = try? configuration.validatedBackupDestination()
        let remote = root == nil ? try? backupControlConfiguration() : nil
        guard (index != nil && root != nil) || remote != nil else {
            backupItems = []
            backupError = nil
            return nil
        }
        backupRefreshGeneration += 1
        let generation = backupRefreshGeneration
        return Task {
            do {
                let items = try await Task.detached(priority: .utility) {
                    if let index, let root { return try index.items(in: root) }
                    if let remote { return try Runner.backupItems(remote) }
                    return []
                }.value
                guard generation == backupRefreshGeneration else { return }
                backupItems = items
                backupError = nil
            } catch {
                guard generation == backupRefreshGeneration else { return }
                backupItems = []
                backupError = String(describing: error)
            }
        }
    }

    private func backupControlConfiguration() throws -> Configuration? {
        guard let host = try configuration.backupHost() else { return nil }
        return Configuration(root: configuration.root, machine: configuration.machine,
                             peer: host.peer, remoteRoot: "", remoteExecutable: host.executable,
                             remoteMachine: host.machine, remoteReceiveOnly: true)
    }

    private func removeLegacyAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: legacyAgentURL)
    }

private final class LocalBackup: @unchecked Sendable {
    let id = UUID()
    private let source: URL
    private let destination: URL
    private let machine: String
    private let stateURL: URL
    private let index: BackupIndex
    private let onCatalog: () -> Void
    private let logger: (String) -> Void
    private let onStopped: (UUID) -> Void
    private let queue = DispatchQueue(label: "git-sync.local-backup")
    private let lock = NSLock()
    private var stopped = false

    init(source: URL, destination: URL, machine: String, stateURL: URL,
         index: BackupIndex, onCatalog: @escaping () -> Void,
         logger: @escaping (String) -> Void, onStopped: @escaping (UUID) -> Void) {
        self.source = source
        self.destination = destination
        self.machine = machine
        self.stateURL = stateURL
        self.index = index
        self.onCatalog = onCatalog
        self.logger = logger
        self.onStopped = onStopped
    }

    func start() {
        queue.async { [self] in run() }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func run() {
        defer { onStopped(id) }
        while !isStopped {
            do {
                let repositories = try OneShot.sync(
                    sourceRoot: source, destinationRoot: destination,
                    machine: machine, stateURL: stateURL, full: true, bareDestination: true
                )
                try index.replaceCatalog(machine: machine, repositories: repositories)
                onCatalog()
                guard !isStopped else { return }
                logger("this Mac is up to date")
                let watcher = Watcher(root: source, repositories: try Repository.discover(in: source))
                let started = Date()
                while !isStopped, !watcher.wait(), Date().timeIntervalSince(started) < 300 {}
            } catch {
                if !isStopped { logger("retrying after: \(error)") }
                for _ in 0..<5 where !isStopped { Thread.sleep(forTimeInterval: 1) }
            }
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }
}

private final class BackupReceiver: @unchecked Sendable {
    let id = UUID()
    private let root: URL
    private let machine: String
    private let stateURL: URL
    private let index: BackupIndex
    private let onCatalog: () -> Void
    private let logger: (String) -> Void
    private let onStopped: (UUID) -> Void
    private let listener: LocalBackupListener
    private let controlListener: LocalBackupListener
    private let queue = DispatchQueue(label: "git-sync.backup-receiver")
    private let controlQueue = DispatchQueue(label: "git-sync.backup-control")
    private let lock = NSLock()
    private var activeConnection: FileHandle?
    private var stopped = false

    init(root: URL, machine: String, stateURL: URL,
         index: BackupIndex, onCatalog: @escaping () -> Void,
         logger: @escaping (String) -> Void, onStopped: @escaping (UUID) -> Void) throws {
        self.root = root
        self.machine = machine
        self.stateURL = stateURL
        self.index = index
        self.onCatalog = onCatalog
        self.logger = logger
        self.onStopped = onStopped
        listener = try LocalBackupListener()
        controlListener = try LocalBackupListener(url: LocalBackupTransport.controlSocketURL)
    }

    func start() {
        queue.async { [self] in run() }
        controlQueue.async { [self] in runControl() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let connection = activeConnection
        lock.unlock()
        listener.close()
        controlListener.close()
        try? connection?.close()
    }

    private func run() {
        defer { stop(); onStopped(id) }
        while !isStopped {
            do {
                let connection = try listener.accept()
                let mode = try LocalBackupTransport.mode(from: connection)
                if mode == LocalBackupTransport.check {
                    try? connection.close()
                    continue
                }
                guard mode == LocalBackupTransport.session else {
                    try? connection.close()
                    throw SyncError.invalidProtocol("Unknown local backup request")
                }
                lock.lock(); activeConnection = connection; lock.unlock()
                do {
                    try Runner.serve(root: root, machine: machine, stateURL: stateURL,
                                     receiveOnly: true,
                                     catalogObserver: { [index, onCatalog] machine, repositories in
                                         try index.replaceCatalog(machine: machine, repositories: repositories)
                                         onCatalog()
                                     },
                                     input: connection, output: connection,
                                     logger: logger)
                } catch {
                    if !isStopped { logger("session ended: \(error)") }
                }
                try? connection.close()
                lock.lock(); activeConnection = nil; lock.unlock()
                if !isStopped { try Runner.prepareBackup(at: root) }
            } catch {
                if !isStopped { logger("stopped: \(error)") }
                return
            }
        }
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func runControl() {
        while !isStopped {
            do {
                let connection = try controlListener.accept()
                defer { try? connection.close() }
                let mode = try LocalBackupTransport.mode(from: connection)
                guard mode == LocalBackupTransport.session else {
                    throw SyncError.invalidProtocol("Unknown local backup control request")
                }
                try BackupControlService.serve(connection, root: root, index: index)
                onCatalog()
            } catch {
                if !isStopped { logger("control request ended: \(error)") }
            }
        }
    }
}
}

struct CountedEvent: Equatable {
    let message: String
    var count = 1
}

func countedEvents(_ events: [String]) -> [CountedEvent] {
    events.reduce(into: []) { result, message in
        if result.last?.message == message {
            result[result.count - 1].count += 1
        } else {
            result.append(CountedEvent(message: message))
        }
    }
}
#endif
