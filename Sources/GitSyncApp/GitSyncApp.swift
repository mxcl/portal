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
            status = "Add a host"
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
            if !isRunning { status = configuration.hosts.isEmpty ? "Add a host" : "Stopped" }
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

    func start() {
        guard !isChecking else { return }
        do {
            try save()
            guard configuration.hosts.contains(where: { !configuration.repositories(for: $0.id).isEmpty }) else {
                throw SyncError.invalidConfiguration("Choose at least two hosts for a folder before starting sync.")
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
            status = configuration.hosts.isEmpty ? "Add a host" : "Stopped"
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
        guard syncProcesses.isEmpty else { return }
        guard let helper = Bundle.main.url(forResource: "git-sync", withExtension: nil) else {
            throw SyncError.invalidConfiguration("The app bundle is missing git-sync. Re-run scripts/install.sh.")
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        do {
            for host in configuration.hosts {
                let repositories = configuration.repositories(for: host.id)
                guard !repositories.isEmpty else { continue }
                let connection = Configuration(root: configuration.root, machine: configuration.machine,
                                               peer: host.peer, remoteRoot: host.root,
                                               remoteExecutable: host.executable, repositories: repositories,
                                               remoteMachine: host.machine)
                try connection.validate()
                try launch(connection, host: host, helper: helper)
            }
        } catch {
            stopProcesses()
            throw error
        }
        isRunning = !syncProcesses.isEmpty
        error = nil
        status = SMAppService.mainApp.status == .requiresApproval
            ? "Standing By — login approval required"
            : (isRunning ? "Standing By" : "No folders selected")
    }

    private func launch(_ configuration: Configuration, host: SyncHost, helper: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let connectionURL = support.appendingPathComponent("connection-\(host.id.uuidString).json")
        let stateURL = support.appendingPathComponent("state-\(host.id.uuidString).json")
        try encoder.encode(configuration).write(to: connectionURL, options: .atomic)

        let process = Process(), output = Pipe()
        process.executableURL = helper
        process.arguments = ["run", "--config", connectionURL.path, "--state", stateURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.appendLogs(data, host: host.machine) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.syncProcesses[host.id] === process else { return }
                output.fileHandleForReading.readabilityHandler = nil
                self.syncProcesses.removeValue(forKey: host.id)
                self.isRunning = !self.syncProcesses.isEmpty
                if process.terminationStatus != 0 {
                    self.appendLog("\(host.machine): git-sync exited with status \(process.terminationStatus)")
                }
                if !self.isRunning { self.status = "Stopped" }
            }
        }
        try process.run()
        syncProcesses[host.id] = process
        appendLog("Started sync with \(host.machine)")
    }

    private func appendLogs(_ data: Data, host: String) {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .forEach { appendLog("\(host): \($0)") }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

    private func stopProcesses() {
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
            status = configuration.hosts.isEmpty ? "Add a host" : "Stopped"
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

struct StatusMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.status)
        if !model.menuLogs.isEmpty {
            Divider()
            Section("Transfers") {
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
        Group {
            if #available(macOS 14.0, *) {
                ForegroundSettingsButton(title: title)
            } else {
                Button(title) {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }
    }
}

@available(macOS 14.0, *)
private struct ForegroundSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    let title: String

    var body: some View {
        Button(title) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Section("This Mac") {
                    HStack {
                        TextField("Projects folder", text: $model.configuration.root)
                        Button("Choose…", action: model.chooseRoot)
                        Button("Refresh", action: model.refreshLocal)
                            .disabled(model.configuration.root.isEmpty || model.isChecking)
                    }
                    TextField("Machine name", text: $model.configuration.machine)
                }
                .disabled(model.configurationLocked)
            }
            .formStyle(.grouped)

            GroupBox("Hosts") {
                Table(model.configuration.hosts, selection: $model.selectedHostID) {
                    TableColumn("Machine", value: \.machine)
                    TableColumn("SSH Host", value: \.peer)
                    TableColumn("Projects Folder", value: \.root)
                }
                HStack {
                    Button(action: model.beginAddingHost) { Label("Add Host", systemImage: "plus") }
                    Button(action: model.removeSelectedHost) { Label("Remove Host", systemImage: "minus") }
                        .disabled(model.selectedHostID == nil)
                    Spacer()
                    if model.isChecking { ProgressView().controlSize(.small) }
                }
            }

            GroupBox("Folders") {
                if model.configuration.folders.isEmpty {
                    VStack {
                        Label("No Git Folders", systemImage: "folder")
                            .font(.headline)
                        Text("Choose the parent folder that contains your repositories.")
                            .foregroundStyle(.secondary)
                    }
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
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(model.status, systemImage: model.isRunning ? "arrow.triangle.2.circlepath" : "pause.circle")
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Spacer()
                Button(model.isChecking ? "Checking…" : "Save & Start", action: model.start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isChecking || model.isRunning)
                if model.canStop { Button("Stop Sync", action: model.stop) }
            }
        }
        .scenePadding()
        .frame(minWidth: 760, minHeight: 560)
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
