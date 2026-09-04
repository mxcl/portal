#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import GitSyncCore

@main
struct GitSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Git Sync", systemImage: model.isPaused ? "pause.circle" : "arrow.triangle.2.circlepath") {
            StatusMenu(model: model)
        }

        Window("Git Sync", id: "projects") {
            ProjectBrowserView(model: model)
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            CommandGroup(after: .toolbar) {
                Button(model.isPaused ? "Resume Sync" : "Pause Sync") {
                    model.isPaused ? model.resume() : model.pause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isConfigured)
            }
        }

        Settings {
            SettingsView(model: model)
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentMinSize)
    }
}

private struct HostDraft {
    var peer = ""
    var root = ""
    var executable = Configuration.defaultRemoteExecutable
}

struct CheckoutRequest: Identifiable {
    let id = UUID()
    let project: String
    let hostID: UUID?
    let branches: [String]
}

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var status = "Not configured"
    @Published var error: String?
    @Published var hostError: String?
    @Published var isChecking = false
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var logs: [String] = []
    @Published var backupItems: [BackupItem] = []
    @Published var backupError: String?
    @Published var restoringBackup: String?
    @Published var selectedHostID: UUID?
    @Published var showingAddHost = false
    @Published var showingRenameHost = false
    @Published var showingOverlapConfirmation = false
    @Published var overlappingRepositories: [String] = []
    @Published var selectedProjectName: String?
    @Published var selectedCommitID: String?
    @Published var projectSnapshot: RepositorySnapshot?
    @Published var projectReadme: RepositoryReadme?
    @Published var projectError: String?
    @Published var isLoadingProject = false
    @Published var placementInProgress: String?
    @Published var remoteProjects: [UUID: [String: PeerProject]] = [:]
    @Published var checkoutRequest: CheckoutRequest?

    fileprivate var hostDraft = HostDraft()
    fileprivate var hostNameDraft = ""

    private var loginItemRegistered: Bool {
        SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
    var launchesAtLogin: Bool { loginItemRegistered }
    var menuLogs: [String] {
        logs.suffix(8).reversed().map { $0.count > 90 ? String($0.prefix(89)) + "…" : $0 }
    }

    private let label = "dev.mxcl.git-sync"
    private let selectedProjectKey = "selected-project-v2"
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GitSync", isDirectory: true)
    private var configURL: URL { support.appendingPathComponent("config-v2.json") }
    private var previousConfigURL: URL { support.appendingPathComponent("config.json") }
    private var legacyConfigURL: URL { support.appendingPathComponent("config-v1-legacy.json") }
    private var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private var pendingConfiguration: AppConfiguration?
    private var syncProcesses: [UUID: Process] = [:]
    private var backupReceiver: BackupReceiver?
    private var localBackup: LocalBackup?
    private var backupIndex: BackupIndex?
    private var backupIndexID: UUID?
    private var backupRefreshGeneration = 0
    private var discoveryTask: Task<Void, Never>?

    init() {
        configuration = AppConfiguration(root: "", machine: Configuration.defaultMachine)
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
        if let saved = UserDefaults.standard.string(forKey: selectedProjectKey),
           configuration.folders.contains(where: { $0.name == saved }) {
            selectedProjectName = saved
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
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.refreshDiscovery()
            }
        }
    }

    var isConfigured: Bool { !configuration.root.isEmpty }

    var projectNames: [String] {
        let archived = Set(archivedProjects.map(\.name))
        return configuration.folders.map(\.name).filter { !archived.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var archivedProjects: [BackupItem] {
        backupItems.filter { $0.status == .archived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func preserveLegacyConfiguration() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: configURL.path),
              manager.fileExists(atPath: previousConfigURL.path),
              !manager.fileExists(atPath: legacyConfigURL.path) else { return }
        try? manager.createDirectory(at: support, withIntermediateDirectories: true)
        try? manager.copyItem(at: previousConfigURL, to: legacyConfigURL)
    }

    func chooseRoot() {
        guard configuration.root.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the folder containing your Git projects"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            configuration.root = panel.url?.path ?? configuration.root
            refreshLocal()
        }
    }

    func pause() {
        guard isConfigured else { return }
        stopProcesses()
        isPaused = true
        status = "Paused"
    }

    func resume() {
        guard isConfigured else { return }
        isPaused = false
        do { try launchAll() } catch { fail(error) }
    }

    func selectProject(_ name: String?) {
        selectedProjectName = name
        if let name { UserDefaults.standard.set(name, forKey: selectedProjectKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedProjectKey) }
        selectedCommitID = nil
        projectSnapshot = nil
        projectReadme = nil
        projectError = nil
        guard let name else { return }
        let local = configuration.folders.first(where: { $0.name == name })?.availableLocally == true
        let localURL = expandedRoot.appendingPathComponent(name, isDirectory: true)
        let backupURL = configuration.backupDestination.map {
            URL(fileURLWithPath: $0.root).appendingPathComponent("\(name).git", isDirectory: true)
        }
        let repositoryURL = local ? localURL : backupURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        guard let repositoryURL else { return }
        isLoadingProject = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let repository = Repository(name: name, url: repositoryURL)
                    return (try repository.snapshot(), repository.readme())
                }.value
                guard selectedProjectName == name else { return }
                projectSnapshot = result.0
                projectReadme = result.1
                isLoadingProject = false
            } catch {
                guard selectedProjectName == name else { return }
                isLoadingProject = false
                projectError = String(describing: error)
            }
        }
    }

    func placement(of project: String, on hostID: UUID?) -> ProjectPlacement {
        if let hostID { return remoteProjects[hostID]?[project]?.placement ?? .unknown }
        guard let folder = configuration.folders.first(where: { $0.name == project }), folder.availableLocally else {
            return .notPresent
        }
        let repository = Repository(name: project, url: expandedRoot.appendingPathComponent(project, isDirectory: true))
        return repository.placement
    }

    func checkOut(_ project: String, hostID: UUID?) {
        let preferred: String?
        if let hostID { preferred = remoteProjects[hostID]?[project]?.defaultBranch }
        else {
            let repository = Repository(name: project, url: expandedRoot.appendingPathComponent(project, isDirectory: true))
            preferred = repository.defaultBranch
        }
        if let preferred {
            setPlacement(.checkedOut, project: project, hostID: hostID, branch: preferred)
            return
        }
        let branches = Set((projectSnapshot?.references ?? []).compactMap { reference -> String? in
            if reference.fullName.hasPrefix("refs/heads/") { return reference.name }
            guard reference.fullName.hasPrefix("refs/remotes/") else { return nil }
            let pieces = reference.name.split(separator: "/", maxSplits: 1)
            return pieces.count == 2 && pieces[1] != "HEAD" ? String(pieces[1]) : nil
        }).sorted()
        guard !branches.isEmpty else {
            error = "No branch is available to check out yet."
            return
        }
        checkoutRequest = CheckoutRequest(project: project, hostID: hostID, branches: branches)
    }

    func setPlacement(_ placement: ProjectPlacement, project: String, hostID: UUID?, branch: String? = nil) {
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
                placementInProgress = nil
                selectProject(project)
                try startHostProcess(hostID)
            } catch {
                placementInProgress = nil
                fail(error)
                try? startHostProcess(hostID)
            }
        }
    }

    func chooseBackupDestination() {
        guard configuration.backupDestination == nil, configuration.backup == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose where this Mac receives backups"
        panel.prompt = "Use for Backups"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let destination = configuration.backupDestination {
            panel.directoryURL = URL(fileURLWithPath: destination.root)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let existing = configuration.backupDestination
        let id = existing.flatMap {
            NSString(string: $0.root).standardizingPath == NSString(string: url.path).standardizingPath
                ? $0.id : nil
        } ?? UUID()
        configuration.backupDestination = BackupDestinationConfiguration(id: id, root: url.path)
        do {
            try save()
            try loadBackupIndex()
            if isRunning { restartIfRunning() }
            else if isConfigured && !isPaused { try launchAll() }
        } catch { fail(error) }
    }

    func unarchiveBackup(_ item: BackupItem, snapshot: BackupSnapshot) {
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
                    selectProject(item.name)
                } catch {
                    restoringBackup = nil
                    fail(error)
                }
            }
        } catch { fail(error) }
    }

    func refreshLocal() {
        guard !configuration.root.isEmpty else { return }
        isChecking = true
        error = nil
        let root = configuration.root
        Task {
            do {
                let names = try await Task.detached(priority: .userInitiated) {
                    try Repository.discover(in: URL(fileURLWithPath: NSString(string: root).expandingTildeInPath)).map(\.name)
                }.value
                try configuration.discoverLocal(names)
                isChecking = false
                error = nil
                try save()
                restartIfRunning()
                selectProject(selectedProjectName ?? projectNames.first)
            } catch { fail(error) }
        }
    }

    func beginAddingHost() {
        hostDraft = HostDraft(root: configuration.root)
        hostError = nil
        showingAddHost = true
    }

    func beginRenamingHost() {
        guard let selectedHostID,
              let host = configuration.hosts.first(where: { $0.id == selectedHostID }) else { return }
        hostNameDraft = host.name
        hostError = nil
        showingRenameHost = true
    }

    func renameHost() {
        guard let selectedHostID else { return }
        do {
            try configuration.renameHost(selectedHostID, name: hostNameDraft)
            try save()
            showingRenameHost = false
        } catch {
            hostError = String(describing: error)
        }
    }

    func addHost() {
        guard !isChecking else { return }
        let probe = Configuration(root: configuration.root, machine: configuration.machine,
                                  peer: hostDraft.peer, remoteRoot: hostDraft.root,
                                  remoteExecutable: hostDraft.executable, repositories: [])
        do { try probe.validate() } catch { hostError = String(describing: error); return }
        isChecking = true
        hostError = nil
        Task {
            do {
                let inspection = try await Task.detached(priority: .userInitiated) {
                    try Runner.inspectPeer(probe)
                }.value
                var candidate = configuration
                let host = SyncHost(machine: inspection.machine, peer: probe.peer,
                                    root: probe.remoteRoot, executable: probe.remoteExecutable)
                let matches = try candidate.addHost(host, repositories: inspection.repositories)
                recordInspection(inspection, hostID: host.id,
                                 knownProjects: candidate.folders.map(\.name))
                isChecking = false
                showingAddHost = false
                await Task.yield()
                if matches.isEmpty {
                    try apply(candidate)
                } else {
                    pendingConfiguration = candidate
                    overlappingRepositories = matches
                    showingOverlapConfirmation = true
                    status = "Confirmation required"
                }
            } catch {
                isChecking = false
                hostError = "The host was not added. \(error)"
            }
        }
    }

    func confirmOverlap() {
        guard let pendingConfiguration else { return }
        showingOverlapConfirmation = false
        self.pendingConfiguration = nil
        do { try apply(pendingConfiguration) } catch { fail(error) }
    }

    func cancelOverlap() {
        showingOverlapConfirmation = false
        pendingConfiguration = nil
        overlappingRepositories = []
        status = isRunning ? "Standing By" : "Stopped"
    }

    func removeSelectedHost() {
        guard let selectedHostID else { return }
        if configuration.backup?.hostID == selectedHostID {
            hostError = "This host owns the backup destination and cannot be removed."
            return
        }
        let soleProjects = configuration.folders.filter {
            !$0.availableLocally && $0.availableHosts == [selectedHostID]
        }.map(\.name)
        if !soleProjects.isEmpty {
            hostError = "This host is the only active location for: \(soleProjects.joined(separator: ", "))."
            return
        }
        configuration.removeHost(selectedHostID)
        remoteProjects.removeValue(forKey: selectedHostID)
        self.selectedHostID = nil
        do {
            try save()
            restartIfRunning()
            if !isRunning { status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped" }
        } catch { fail(error) }
    }

    func chooseBackupHost(_ hostID: UUID) {
        guard configuration.backup == nil, configuration.backupDestination == nil else { return }
        configuration.backup = BackupConfiguration(hostID: hostID)
        configurationChanged()
        refreshBackupItems()
    }

    func setSyncCheckouts(_ enabled: Bool) {
        configuration.syncCheckouts = enabled
        configurationChanged()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled && !loginItemRegistered { try SMAppService.mainApp.register() }
            if !enabled && loginItemRegistered { try SMAppService.mainApp.unregister() }
            objectWillChange.send()
        } catch { fail(error) }
    }

    func quit() {
        stopProcesses()
        NSApplication.shared.terminate(nil)
    }

    private func apply(_ candidate: AppConfiguration) throws {
        configuration = candidate
        overlappingRepositories = []
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
        guard let helper = Bundle.main.url(forResource: "git-sync", withExtension: nil) else {
            throw SyncError.invalidConfiguration("The app bundle is missing git-sync. Re-run scripts/install.sh.")
        }
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
        guard let helper = Bundle.main.url(forResource: "git-sync", withExtension: nil) else {
            throw SyncError.invalidConfiguration("The app bundle is missing git-sync. Re-run scripts/install.sh.")
        }
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
        status = SMAppService.mainApp.status == .requiresApproval
            ? "Standing By — login approval required"
            : (isRunning ? "Standing By" : "No folders selected")
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
            if selectedProjectName == nil { selectedProjectName = projectNames.first }
        }
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
        isChecking = false
        try? save()
        if startAfter {
            do { try launchAll() } catch { fail(error) }
        } else {
            status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped"
        }
        selectProject(selectedProjectName ?? projectNames.first)
    }

    private func refreshDiscovery() async {
        guard isConfigured, !isChecking, placementInProgress == nil else { return }
        let original = configuration
        let root = expandedRoot
        if let names = try? await Task.detached(priority: .utility, operation: {
            try Repository.discover(in: root).map(\.name)
        }).value {
            try? configuration.discoverLocal(names)
        }
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
        if let selectedProjectName { selectProject(selectedProjectName) }
        else { selectProject(projectNames.first ?? archivedProjects.first?.name) }
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

    private func loadBackupIndex() throws {
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

    private func refreshBackupItems() {
        let index = backupIndex
        let root = try? configuration.validatedBackupDestination()
        let remote = root == nil ? try? backupControlConfiguration() : nil
        guard (index != nil && root != nil) || remote != nil else {
            backupItems = []
            backupError = nil
            return
        }
        backupRefreshGeneration += 1
        let generation = backupRefreshGeneration
        Task {
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

struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status)
        if !model.menuLogs.isEmpty {
            Divider()
            Section("Event Log") {
                ForEach(Array(model.menuLogs.enumerated()), id: \.offset) { Text($0.element) }
            }
        }
        Divider()
        Button(model.isPaused ? "Resume Sync" : "Pause Sync") {
            model.isPaused ? model.resume() : model.pause()
        }
        .disabled(!model.isConfigured)
        Button("Open Git Sync") {
            openWindow(id: "projects")
            NSApplication.shared.activate()
        }
        settingsLink("Settings…").keyboardShortcut(",", modifiers: .command)
        if model.status.contains("approval") { Button("Login Items…", action: model.openLoginItems) }
        Divider()
        Button("Quit Git Sync", action: model.quit)
    }

    private func settingsLink(_ title: String) -> some View {
        Button(title) {
            openSettings()
            NSApplication.shared.activate()
        }
    }
}

struct ProjectBrowserView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var visibility: NavigationSplitViewVisibility = .all

    private var projects: [String] {
        model.projectNames.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }
    private var archived: [BackupItem] {
        model.archivedProjects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: Binding(get: { model.selectedProjectName }, set: model.selectProject)) {
                Section("Projects") {
                    ForEach(projects, id: \.self) { name in
                        ProjectRow(name: name, model: model).tag(name)
                    }
                }
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { item in
                            Label(item.name, systemImage: "archivebox").tag(item.name)
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .searchable(text: $search, placement: .sidebar, prompt: "Projects")
            .overlay {
                if projects.isEmpty && archived.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } content: {
            ProjectHistoryView(model: model)
        } detail: {
            ProjectDetailView(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 520)
        .onAppear {
            if model.selectedProjectName == nil { model.selectProject(model.projectNames.first) }
        }
        .sheet(item: $model.checkoutRequest) { request in
            BranchPicker(request: request, model: model)
        }
    }
}

private struct BranchPicker: View {
    let request: CheckoutRequest
    @ObservedObject var model: AppModel
    @State private var branch: String

    init(request: CheckoutRequest, model: AppModel) {
        self.request = request
        self.model = model
        _branch = State(initialValue: request.branches.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a Branch").font(.title2.bold())
            Picker("Branch", selection: $branch) {
                ForEach(request.branches, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Button("Cancel") { model.checkoutRequest = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Check Out") {
                    model.checkoutRequest = nil
                    model.setPlacement(.checkedOut, project: request.project,
                                       hostID: request.hostID, branch: branch)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

private struct ProjectRow: View {
    let name: String
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            if let folder = model.configuration.folders.first(where: { $0.name == name }) {
                if folder.availableLocally { Circle().fill(.primary).frame(width: 6, height: 6) }
                ForEach(model.configuration.hosts.filter { folder.availableHosts.contains($0.id) }) { _ in
                    Circle().stroke(.secondary, lineWidth: 1).frame(width: 6, height: 6)
                }
            }
        }
        .help(projectSummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projectSummary)
    }

    private var projectSummary: String {
        guard let folder = model.configuration.folders.first(where: { $0.name == name }) else { return name }
        let count = (folder.availableLocally ? 1 : 0) + folder.availableHosts.count
        return "\(name) — on \(count) host\(count == 1 ? "" : "s")"
    }
}

private struct ProjectHistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if !model.isConfigured {
                ContentUnavailableView {
                    Label("Choose a Projects Folder", systemImage: "folder.badge.plus")
                } description: {
                    Text("Set up this Mac to discover its Git projects.")
                } actions: {
                    Button("Open Settings") { openSettings(); NSApplication.shared.activate() }
                }
            } else if model.selectedProjectName == nil {
                ContentUnavailableView("Select a Project", systemImage: "sidebar.left")
            } else if model.isLoadingProject {
                ProgressView("Reading Git history…")
            } else if let error = model.projectError {
                ContentUnavailableView {
                    Label("Couldn’t Read Git History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { model.selectProject(model.selectedProjectName) }
                }
            } else if let snapshot = model.projectSnapshot {
                CommitList(snapshot: snapshot, selection: $model.selectedCommitID)
            } else {
                ContentUnavailableView("Not on This Mac", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Bring this project to this Mac to render its Git tree and README."))
            }
        }
        .navigationTitle(model.selectedProjectName ?? "Git Tree")
        .toolbar {
            ToolbarItem {
                Button("Show Project Details", systemImage: "info.circle") { model.selectedCommitID = nil }
                    .disabled(model.selectedProjectName == nil || model.selectedCommitID == nil)
            }
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { model.selectProject(model.selectedProjectName) } }
        }
    }
}

private struct CommitList: View {
    let snapshot: RepositorySnapshot
    @Binding var selection: String?
    private var graph: [String: CommitGraphPosition] { CommitGraph.positions(snapshot.commits) }

    var body: some View {
        List(snapshot.commits, selection: $selection) { commit in
            CommitRow(commit: commit,
                      references: snapshot.references.filter { $0.oid == commit.oid },
                      graph: graph[commit.oid] ?? .init(lane: 0, continuing: [], parents: [], width: 1))
                .tag(commit.oid)
        }
        .overlay {
            if snapshot.commits.isEmpty {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }
}

private struct CommitRow: View {
    let commit: RepositoryCommit
    let references: [RepositoryReference]
    let graph: CommitGraphPosition

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CommitGraphView(position: graph)
                .frame(width: CGFloat(max(1, graph.width)) * 12 + 8, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(commit.subject).lineLimit(1)
                    ForEach(references.prefix(4)) { reference in
                        Text(reference.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                HStack {
                    Text(commit.author)
                    Text(commit.oid.prefix(8)).monospaced()
                    Spacer()
                    Text(commit.date, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct CommitGraphPosition {
    let lane: Int
    let continuing: [Int]
    let parents: [Int]
    let width: Int
}

private enum CommitGraph {
    static func positions(_ commits: [RepositoryCommit]) -> [String: CommitGraphPosition] {
        var lanes: [String] = []
        var result: [String: CommitGraphPosition] = [:]
        for commit in commits {
            let lane: Int
            if let existing = lanes.firstIndex(of: commit.oid) { lane = existing }
            else { lanes.append(commit.oid); lane = lanes.count - 1 }
            let continuing = lanes.indices.filter { $0 != lane }.map { $0 }
            lanes.remove(at: lane)
            for parent in commit.parents.reversed() where !lanes.contains(parent) { lanes.insert(parent, at: min(lane, lanes.count)) }
            let parents = commit.parents.compactMap { lanes.firstIndex(of: $0) }
            result[commit.oid] = CommitGraphPosition(lane: lane, continuing: continuing, parents: parents,
                                                     width: max(lane + 1, lanes.count))
        }
        return result
    }
}

private struct CommitGraphView: View {
    let position: CommitGraphPosition

    var body: some View {
        Canvas { context, size in
            let x: (Int) -> CGFloat = { CGFloat($0) * 12 + 8 }
            var path = Path()
            for lane in position.continuing {
                path.move(to: CGPoint(x: x(lane), y: 0)); path.addLine(to: CGPoint(x: x(lane), y: size.height))
            }
            path.move(to: CGPoint(x: x(position.lane), y: 0))
            path.addLine(to: CGPoint(x: x(position.lane), y: size.height / 2))
            for parent in position.parents {
                path.move(to: CGPoint(x: x(position.lane), y: size.height / 2))
                path.addLine(to: CGPoint(x: x(parent), y: size.height))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.55)), lineWidth: 1.5)
            context.fill(Path(ellipseIn: CGRect(x: x(position.lane) - 4, y: size.height / 2 - 4, width: 8, height: 8)),
                         with: .color(.accentColor))
        }
        .accessibilityHidden(true)
    }
}

private struct ProjectDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let name = model.selectedProjectName {
            if let commitID = model.selectedCommitID,
               let commit = model.projectSnapshot?.commits.first(where: { $0.oid == commitID }) {
                CommitDetail(commit: commit, references: model.projectSnapshot?.references.filter { $0.oid == commitID } ?? [])
            } else if let archived = model.archivedProjects.first(where: { $0.name == name }) {
                ArchivedProjectDetail(item: archived, model: model)
            } else {
                ProjectOverview(name: name, model: model)
            }
        } else {
            ContentUnavailableView("Project Details", systemImage: "info.circle")
        }
    }
}

private struct ProjectOverview: View {
    let name: String
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.title2.bold())
                    Text("Project").foregroundStyle(.secondary)
                }
                HostControls(project: name, model: model)
                Divider()
                if let readme = model.projectReadme {
                    HStack {
                        Text("README").font(.headline)
                        Spacer()
                        Text(readme.source).font(.caption).foregroundStyle(.secondary)
                    }
                    MarkdownDocument(markdown: readme.markdown)
                } else if model.projectSnapshot != nil {
                    ContentUnavailableView("No README", systemImage: "doc.plaintext")
                        .frame(minHeight: 180)
                } else {
                    Text("Bring this project to this Mac to render its details and README.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle(name)
    }
}

private struct HostControls: View {
    let project: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hosts").font(.headline)
            PlacementRow(name: model.configuration.machine, placement: model.placement(of: project, on: nil),
                         progress: model.placementInProgress == "local") {
                $0 == .checkedOut ? model.checkOut(project, hostID: nil)
                    : model.setPlacement($0, project: project, hostID: nil)
            }
            ForEach(model.configuration.hosts) { host in
                PlacementRow(name: host.name, placement: model.placement(of: project, on: host.id),
                             progress: model.placementInProgress == host.id.uuidString) {
                    $0 == .checkedOut ? model.checkOut(project, hostID: host.id)
                        : model.setPlacement($0, project: project, hostID: host.id)
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
}

private struct PlacementRow: View {
    let name: String
    let placement: ProjectPlacement
    let progress: Bool
    let change: (ProjectPlacement) -> Void

    var body: some View {
        HStack {
            Label(name, systemImage: "desktopcomputer")
            Spacer()
            if progress { ProgressView().controlSize(.small) }
            Menu {
                switch placement {
                case .checkedOut:
                    Button("Keep Mirrored") { change(.mirrored) }
                case .mirrored:
                    Button("Check Out") { change(.checkedOut) }
                    Button("Move Repository to Trash", role: .destructive) { change(.notPresent) }
                case .notPresent:
                    Button("Mirror on This Host") { change(.mirrored) }
                case .unknown:
                    Text("Host unavailable")
                }
            } label: {
                Label(placement.title, systemImage: placement.symbol)
                    .foregroundStyle(placement == .unknown ? .secondary : .primary)
            }
            .menuStyle(.borderlessButton)
            .disabled(progress || placement == .unknown)
        }
    }
}

private extension ProjectPlacement {
    var title: String {
        switch self {
        case .checkedOut: "Checked Out"
        case .mirrored: "Mirrored"
        case .notPresent: "Not Present"
        case .unknown: "Unavailable"
        }
    }
    var symbol: String {
        switch self {
        case .checkedOut: "checkmark.circle.fill"
        case .mirrored: "externaldrive.fill"
        case .notPresent: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct CommitDetail: View {
    let commit: RepositoryCommit
    let references: [RepositoryReference]

    var body: some View {
        Form {
            Section("Commit") { Text(commit.message).textSelection(.enabled) }
            LabeledContent("Author", value: commit.author)
            LabeledContent("Date") { Text(commit.date.formatted(date: .long, time: .standard)) }
            LabeledContent("SHA") { Text(commit.oid).monospaced().textSelection(.enabled) }
            if !commit.parents.isEmpty {
                LabeledContent("Parents") {
                    VStack(alignment: .trailing) { ForEach(commit.parents, id: \.self) { Text($0).monospaced() } }
                }
            }
            if !references.isEmpty {
                Section("References") { ForEach(references) { Text($0.name) } }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(commit.subject)
    }
}

private struct ArchivedProjectDetail: View {
    let item: BackupItem
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Archived", systemImage: "archivebox.fill").font(.title2.bold())
            Text(item.name).font(.title3)
            Text("This project has no active checkout or mirror. Its repository is stored only at the backup destination.")
                .foregroundStyle(.secondary)
            if model.restoringBackup == item.name {
                ProgressView("Bringing to this Mac…")
            } else if item.snapshots.count == 1, let snapshot = item.snapshots.first {
                Button("Bring to This Mac") { model.unarchiveBackup(item, snapshot: snapshot) }
            } else if !item.snapshots.isEmpty {
                Menu("Bring to This Mac") {
                    ForEach(item.snapshots) { snapshot in
                        Button("From \(snapshot.machine)") { model.unarchiveBackup(item, snapshot: snapshot) }
                    }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let readme = model.projectReadme {
                Divider()
                HStack {
                    Text("README").font(.headline)
                    Spacer()
                    Text(readme.source).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView { MarkdownDocument(markdown: readme.markdown) }
            }
            Spacer()
        }
        .padding(20)
        .navigationTitle(item.name)
    }
}

private struct MarkdownDocument: View {
    let markdown: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading1: inline(block.text).font(.title2.bold())
                case .heading2: inline(block.text).font(.title3.bold())
                case .heading3: inline(block.text).font(.headline)
                case .list: HStack(alignment: .top) { Text("•"); inline(block.text) }
                case .code:
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(.body, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                case .paragraph: inline(block.text)
                case .space: Spacer().frame(height: 4)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [MarkdownBlock] {
        var result: [MarkdownBlock] = [], code: [String] = []
        var inCode = false
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                if inCode { result.append(MarkdownBlock(kind: .code, text: code.joined(separator: "\n"))); code = [] }
                inCode.toggle()
            } else if inCode { code.append(line) }
            else if line.hasPrefix("### ") { result.append(MarkdownBlock(kind: .heading3, text: String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { result.append(MarkdownBlock(kind: .heading2, text: String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { result.append(MarkdownBlock(kind: .heading1, text: String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { result.append(MarkdownBlock(kind: .list, text: String(line.dropFirst(2)))) }
            else if line.hasPrefix("    ") { result.append(MarkdownBlock(kind: .code, text: String(line.dropFirst(4)))) }
            else if line.isEmpty { result.append(MarkdownBlock(kind: .space, text: "")) }
            else { result.append(MarkdownBlock(kind: .paragraph, text: line)) }
        }
        if !code.isEmpty { result.append(MarkdownBlock(kind: .code, text: code.joined(separator: "\n"))) }
        return result
    }

    private func inline(_ source: String) -> Text {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map(Text.init) ?? Text(source)
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind { case heading1, heading2, heading3, list, code, paragraph, space }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            Form {
                Section("This Mac") {
                    LabeledContent("Projects folder") {
                        if model.configuration.root.isEmpty {
                            Button("Choose…", action: model.chooseRoot)
                        } else {
                            Text(model.configuration.root).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                    LabeledContent("Machine name") {
                        if model.configuration.root.isEmpty {
                            TextField("Machine name", text: $model.configuration.machine).frame(width: 220)
                        } else {
                            Text(model.configuration.machine).textSelection(.enabled)
                        }
                    }
                    Text("The projects folder and Git identity are fixed after setup.").foregroundStyle(.secondary)
                }
                Section("Startup") {
                    Toggle("Launch Git Sync at login", isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchAtLogin))
                }
                Section("Checkouts") {
                    Toggle("Fast-forward matching clean checkouts", isOn: Binding(
                        get: { model.configuration.syncCheckouts == true }, set: model.setSyncCheckouts
                    ))
                    Text("Off by default. When enabled, only matching branches with clean working trees are advanced.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Hosts").font(.headline)
                    Spacer()
                    if model.isChecking { ProgressView().controlSize(.small) }
                    Button(action: model.beginAddingHost) { Label("Add Host", systemImage: "plus") }
                        .disabled(!model.isConfigured)
                    Button(action: model.beginRenamingHost) { Label("Rename Host", systemImage: "pencil") }
                        .disabled(model.selectedHostID == nil)
                    Button(action: model.removeSelectedHost) { Label("Remove Host", systemImage: "minus") }
                        .disabled(model.selectedHostID == nil)
                }
                Table(model.configuration.hosts, selection: $model.selectedHostID) {
                    TableColumn("Name", value: \.name)
                    TableColumn("SSH Host", value: \.peer)
                    TableColumn("Projects Folder", value: \.root)
                }
                if let error = model.hostError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Text("Removing a host forgets the connection only; it never deletes repositories or Git refs.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("Hosts", systemImage: "desktopcomputer.and.arrow.down") }

            Form {
                Section("Destination") {
                    if let destination = model.configuration.backupDestination {
                        LabeledContent("Host", value: model.configuration.machine)
                        LabeledContent("Folder", value: destination.root)
                    } else if let backup = model.configuration.backup,
                              let host = model.configuration.hosts.first(where: { $0.id == backup.hostID }) {
                        LabeledContent("Host", value: host.name)
                        Text("The destination folder is configured on that host.").foregroundStyle(.secondary)
                    } else {
                        Menu("Choose Backup Host…") {
                            Button("This Mac…", action: model.chooseBackupDestination)
                            ForEach(model.configuration.hosts) { host in
                                Button(host.name) { model.chooseBackupHost(host.id) }
                            }
                        }
                        .disabled(!model.isConfigured)
                        Text("Once chosen, the backup destination cannot be changed in this version.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Behavior") {
                    Text("Every known project is backed up continuously. A project becomes Archived only after every host confirms it is absent.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Backup", systemImage: "externaldrive") }
        }
        .contentMargins(.vertical, 20, for: .scrollContent)
        .frame(minWidth: 720, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Label(model.status, systemImage: model.isPaused ? "pause.circle" : "arrow.triangle.2.circlepath")
                if let error = model.error {
                    Text(error).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(isPresented: $model.showingAddHost) { AddHostView(model: model) }
        .sheet(isPresented: $model.showingRenameHost) { RenameHostView(model: model) }
        .sheet(isPresented: $model.showingOverlapConfirmation) {
            VStack(alignment: .leading) {
                Text("Are You Sure?").font(.title2.bold())
                Text("These folders already contain Git repositories on both hosts. Sync keeps both working copies independent, but their names will be paired.")
                List(model.overlappingRepositories, id: \.self) { Text($0) }
                HStack {
                    Button("Cancel", action: model.cancelOverlap).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Sync Matches", action: model.confirmOverlap).keyboardShortcut(.defaultAction)
                }
            }
            .scenePadding()
            .frame(width: 480, height: 360)
            .interactiveDismissDisabled()
        }
    }
}

private struct RenameHostView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Rename Host").font(.title2.bold())
            TextField("Name", text: $model.hostNameDraft)
            Text("This changes how the host appears in Git Sync, not its Git identity.")
                .foregroundStyle(.secondary)
            if let error = model.hostError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { model.showingRenameHost = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename", action: model.renameHost).keyboardShortcut(.defaultAction)
            }
        }
        .scenePadding()
        .frame(width: 440, height: 180)
    }
}

private struct AddHostView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add Host").font(.title2.bold())
            Form {
                TextField("SSH host", text: $model.hostDraft.peer)
                TextField("Projects folder", text: $model.hostDraft.root)
                TextField("git-sync executable", text: $model.hostDraft.executable)
            }
            .formStyle(.grouped)
            if let error = model.hostError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel") { model.showingAddHost = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.isChecking ? "Checking…" : "Add", action: model.addHost)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isChecking)
            }
        }
        .scenePadding()
        .frame(width: 520, height: 280)
        .interactiveDismissDisabled(model.isChecking)
    }
}
#else
import Foundation
@main enum GitSyncApp { static func main() { print("Git Sync.app is available on macOS only") } }
#endif
