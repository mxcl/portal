#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import GitSyncCore

@main
struct GitSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Git Sync", systemImage: model.isRunning ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle") {
            StatusMenu(model: model)
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

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var status = "Not configured"
    @Published var error: String?
    @Published var hostError: String?
    @Published var isChecking = false
    @Published var isRunning = false
    @Published var logs: [String] = []
    @Published var selectedHostID: UUID?
    @Published var showingAddHost = false
    @Published var showingOverlapConfirmation = false
    @Published var overlappingRepositories: [String] = []

    fileprivate var hostDraft = HostDraft()

    private var loginItemRegistered: Bool {
        SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
    var canStop: Bool { isRunning || loginItemRegistered }
    var configurationLocked: Bool { isRunning || isChecking || showingOverlapConfirmation }
    var menuLogs: [String] {
        logs.suffix(8).reversed().map { $0.count > 90 ? String($0.prefix(89)) + "…" : $0 }
    }

    private let label = "dev.mxcl.git-sync"
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GitSync", isDirectory: true)
    private var configURL: URL { support.appendingPathComponent("config.json") }
    private var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private var pendingConfiguration: AppConfiguration?
    private var syncProcesses: [UUID: Process] = [:]
    private var backupReceiver: BackupReceiver?
    private var localBackup: LocalBackup?

    init() {
        configuration = AppConfiguration(root: "", machine: Configuration.defaultMachine)
        removeLegacyAgent()
        if let data = try? Data(contentsOf: configURL) {
            if let saved = try? JSONDecoder().decode(AppConfiguration.self, from: data) {
                configuration = saved
            } else if let legacy = try? JSONDecoder().decode(Configuration.self, from: data) {
                configuration.root = legacy.root
                configuration.machine = legacy.machine
            }
        }
        refreshLocalNow()
        let startAfterInspection = SMAppService.mainApp.status == .enabled
        if !configuration.hosts.isEmpty {
            isChecking = true
            status = "Checking Hosts"
            Task { await refreshHostIdentities(startAfter: startAfterInspection) }
        } else if startAfterInspection {
            do { try launchAll() } catch { fail(error) }
        } else {
            status = configuration.backupDestination == nil ? "Add a host" : "Stopped"
        }
    }

    func chooseRoot() {
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

    func chooseBackupDestination() {
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
            status = "Stopped"
        } catch { fail(error) }
    }

    func clearBackupDestination() {
        configuration.backupDestination = nil
        do { try save() } catch { fail(error) }
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
            } catch { fail(error) }
        }
    }

    func beginAddingHost() {
        hostDraft = HostDraft(root: configuration.root)
        hostError = nil
        showingAddHost = true
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
        configuration.removeHost(selectedHostID)
        self.selectedHostID = nil
        do {
            try save()
            restartIfRunning()
            if !isRunning { status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped" }
        } catch { fail(error) }
    }

    func setLocal(_ enabled: Bool, folder: String) {
        guard let index = configuration.folders.firstIndex(where: { $0.name == folder }) else { return }
        configuration.folders[index].isLocal = enabled
        configurationChanged()
    }

    func setHost(_ hostID: UUID, enabled: Bool, folder: String) {
        guard let index = configuration.folders.firstIndex(where: { $0.name == folder }) else { return }
        if enabled { configuration.folders[index].hosts.insert(hostID) }
        else { configuration.folders[index].hosts.remove(hostID) }
        configurationChanged()
    }

    func setBackupEnabled(_ enabled: Bool) {
        configuration.backup = enabled
            ? configuration.hosts.first.map { BackupConfiguration(hostID: $0.id, root: "") }
            : nil
    }

    func setBackupHost(_ hostID: UUID) {
        guard let backup = configuration.backup, backup.hostID != hostID else { return }
        configuration.backup = BackupConfiguration(id: backup.id, hostID: hostID)
    }

    func start() {
        guard !isChecking else { return }
        do {
            try save()
            guard configuration.backup != nil || configuration.backupDestination != nil
                    || configuration.hosts.contains(where: {
                !configuration.repositories(for: $0.id).isEmpty
            }) else {
                throw SyncError.invalidConfiguration("Choose folders to sync or configure a backup before starting.")
            }
            if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                try SMAppService.mainApp.register()
            }
            try launchAll()
        } catch { fail(error) }
    }

    func stop() {
        stopProcesses()
        do {
            if loginItemRegistered { try SMAppService.mainApp.unregister() }
            status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped"
        } catch { fail(error) }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func quit() {
        stopProcesses()
        NSApplication.shared.terminate(nil)
    }

    private func apply(_ candidate: AppConfiguration) throws {
        let wasRunning = isRunning
        configuration = candidate
        overlappingRepositories = []
        error = nil
        try save()
        if wasRunning { restartIfRunning() }
        else { status = "Stopped" }
    }

    private func configurationChanged() {
        do {
            try save()
            restartIfRunning()
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
                let receiver = try BackupReceiver(
                    root: destination, machine: configuration.machine,
                    stateURL: support.appendingPathComponent(
                        "backup-receiver-\(destinationConfiguration.id.uuidString).json"
                    ),
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
                                               remoteMachine: host.machine)
                try connection.validate()
                try launch(connection, id: host.id, name: host.machine, helper: helper)
            }
            if let backup = configuration.backup, let host = try configuration.backupHost() {
                let connection = Configuration(
                    root: configuration.root, machine: configuration.machine,
                    peer: host.peer, remoteRoot: "", remoteExecutable: host.executable,
                    remoteMachine: host.machine,
                    remoteReceiveOnly: true
                )
                try connection.validate()
                try launch(connection, id: backup.id, name: "Backup on \(host.machine)", helper: helper)
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
            if process.isRunning { process.terminate() }
        }
        isRunning = false
    }

    private func fail(_ error: Error) {
        isChecking = false
        self.error = String(describing: error)
        status = isRunning ? "Standing By" : "Stopped"
        appendLog("Error: \(error)")
    }

    private func refreshLocalNow() {
        guard !configuration.root.isEmpty else { return }
        let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
        if let names = try? Repository.discover(in: root).map(\.name) {
            try? configuration.discoverLocal(names)
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
            }
        }
        isChecking = false
        try? save()
        if startAfter {
            do { try launchAll() } catch { fail(error) }
        } else {
            status = configuration.hosts.isEmpty && configuration.backupDestination == nil ? "Add a host" : "Stopped"
        }
    }

    private var expandedRoot: URL {
        URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath).standardizedFileURL
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
    private let logger: (String) -> Void
    private let onStopped: (UUID) -> Void
    private let queue = DispatchQueue(label: "git-sync.local-backup")
    private let lock = NSLock()
    private var stopped = false

    init(source: URL, destination: URL, machine: String, stateURL: URL,
         logger: @escaping (String) -> Void, onStopped: @escaping (UUID) -> Void) {
        self.source = source
        self.destination = destination
        self.machine = machine
        self.stateURL = stateURL
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
                try OneShot.sync(sourceRoot: source, destinationRoot: destination,
                                 machine: machine, stateURL: stateURL, full: true)
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
    private let logger: (String) -> Void
    private let onStopped: (UUID) -> Void
    private let listener: LocalBackupListener
    private let queue = DispatchQueue(label: "git-sync.backup-receiver")
    private let lock = NSLock()
    private var activeConnection: FileHandle?
    private var stopped = false

    init(root: URL, machine: String, stateURL: URL,
         logger: @escaping (String) -> Void, onStopped: @escaping (UUID) -> Void) throws {
        self.root = root
        self.machine = machine
        self.stateURL = stateURL
        self.logger = logger
        self.onStopped = onStopped
        listener = try LocalBackupListener()
    }

    func start() {
        queue.async { [self] in run() }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let connection = activeConnection
        lock.unlock()
        listener.close()
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
                                     receiveOnly: true, input: connection, output: connection,
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
}

struct StatusMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.status)
        if !model.menuLogs.isEmpty {
            Divider()
            Section("Event Log") {
                ForEach(Array(model.menuLogs.enumerated()), id: \.offset) { Text($0.element) }
            }
        }
        Divider()
        if model.canStop { Button("Stop Sync", action: model.stop) }
        else { settingsLink("Start Sync…") }
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

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            TabView {
                Form {
                    Section("Projects") {
                        HStack {
                            TextField("Projects folder", text: $model.configuration.root)
                            Button("Choose…", action: model.chooseRoot)
                            Button("Refresh", action: model.refreshLocal)
                                .disabled(model.configuration.root.isEmpty || model.isChecking)
                        }
                        Text("Choose the folder that contains this Mac’s Git repositories.")
                            .foregroundStyle(.secondary)
                    }
                    Section("Identity") {
                        TextField("Machine name", text: $model.configuration.machine)
                        Text("This name identifies the Mac to your other hosts.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .disabled(model.configurationLocked)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .tabItem { Label("This Mac", systemImage: "desktopcomputer") }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Hosts").font(.headline)
                        Spacer()
                        if model.isChecking { ProgressView().controlSize(.small) }
                        Button(action: model.beginAddingHost) { Label("Add Host", systemImage: "plus") }
                        Button(action: model.removeSelectedHost) { Label("Remove Host", systemImage: "minus") }
                            .disabled(model.selectedHostID == nil)
                    }
                    Table(model.configuration.hosts, selection: $model.selectedHostID) {
                        TableColumn("Machine", value: \.machine)
                        TableColumn("SSH Host", value: \.peer)
                        TableColumn("Projects Folder", value: \.root)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Hosts", systemImage: "desktopcomputer.and.arrow.down") }

                VStack(alignment: .leading, spacing: 12) {
                    if model.configuration.folders.isEmpty {
                        ContentUnavailableView(
                            "No Git Folders",
                            systemImage: "folder",
                            description: Text("Choose the parent folder that contains your repositories.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Table(model.configuration.folders) {
                            TableColumn("Folder", value: \.name)
                            TableColumn("This Mac") { folder in
                                Toggle(model.configuration.machine, isOn: Binding(
                                    get: { folder.isLocal },
                                    set: { model.setLocal($0, folder: folder.name) }
                                ))
                                .toggleStyle(.checkbox)
                            }
                            TableColumn("Other Hosts") { folder in
                                HStack {
                                    ForEach(model.configuration.hosts) { host in
                                        Toggle(host.machine, isOn: Binding(
                                            get: { folder.hosts.contains(host.id) },
                                            set: { model.setHost(host.id, enabled: $0, folder: folder.name) }
                                        ))
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                    }
                    Text("A folder syncs with a host only while both checkboxes are selected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label("Folders", systemImage: "folder") }

                Form {
                    Section("Back Up This Mac") {
                        Toggle("Back up every repository", isOn: Binding(
                            get: { model.configuration.backup != nil },
                            set: model.setBackupEnabled
                        ))
                        .disabled(model.configuration.hosts.isEmpty)
                        .opacity(model.isRunning ? 0.45 : 1)

                        if model.isRunning {
                            Text("can only be toggled when stopped")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.configuration.hosts.isEmpty {
                            Text("Add a host in the Hosts tab before configuring a backup.")
                                .foregroundStyle(.secondary)
                        } else if let backup = model.configuration.backup {
                            Picker("Backup host", selection: Binding(
                                get: { model.configuration.backup?.hostID ?? backup.hostID },
                                set: model.setBackupHost
                            )) {
                                ForEach(model.configuration.hosts) { host in
                                    Text(host.machine).tag(host.id)
                                }
                            }
                            Text("Choose the destination in Git Sync on the backup host. Backups receive every repository but never publish changes back.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Receive Backups on This Mac") {
                        HStack {
                            if let destination = model.configuration.backupDestination {
                                Text(destination.root)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("Clear", action: model.clearBackupDestination)
                            } else {
                                Text("No destination selected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            Button("Choose…", action: model.chooseBackupDestination)
                        }
                        Text("The folder must differ from this Mac’s projects folder. Git Sync.app—not SSH—owns access to the selected destination.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .disabled(model.configurationLocked)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .tabItem { Label("Backup", systemImage: "externaldrive") }
            }

            Divider()

            HStack {
                Label(model.status, systemImage: model.isRunning ? "arrow.triangle.2.circlepath" : "pause.circle")
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                if model.canStop { Button("Stop Sync", action: model.stop) }
                Button(model.isChecking ? "Checking…" : "Save & Start", action: model.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isChecking || model.isRunning)
            }
        }
        .scenePadding()
        .frame(minWidth: 720, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $model.showingAddHost) { AddHostView(model: model) }
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
