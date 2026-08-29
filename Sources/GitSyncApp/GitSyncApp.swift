#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import GitSyncCore

@main
struct GitSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Label("Git Sync", systemImage: model.isRunning ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var root = ""
    @Published var machine = AppModel.defaultMachine
    @Published var peer = ""
    @Published var remoteRoot = ""
    @Published var remoteExecutable = Configuration.defaultRemoteExecutable
    @Published var status = "Not configured"
    @Published var error: String?
    @Published var isChecking = false
    @Published var isRunning = false
    @Published var logs: [String] = []
    @Published var overlappingRepositories: [String] = []
    @Published var showingOverlapConfirmation = false

    private let label = "dev.mxcl.git-sync"
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GitSync", isDirectory: true)
    private var configURL: URL { support.appendingPathComponent("config.json") }
    private var stateURL: URL { support.appendingPathComponent("state.json") }
    private var legacyAgentURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private var pendingConfiguration: Configuration?
    private var syncProcess: Process?

    init() {
        removeLegacyAgent()
        if let config = try? Configuration.load(configURL) {
            root = config.root; machine = config.machine; peer = config.peer
            remoteRoot = config.remoteRoot
            remoteExecutable = config.remoteExecutable == "git-sync" ? Configuration.defaultRemoteExecutable : config.remoteExecutable
            if SMAppService.mainApp.status == .enabled {
                do { try launch(configuration: currentConfiguration()) } catch { fail(error) }
            } else {
                status = "Stopped"
            }
        }
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder containing your Git projects"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { root = panel.url?.path ?? root }
    }

    func start() {
        do {
            let configuration = currentConfiguration()
            try configuration.validate()
            isChecking = true
            error = nil
            status = "Checking destination…"
            Task {
                do {
                    let matches = try await Task.detached(priority: .userInitiated) {
                        try Runner.overlappingRepositories(configuration)
                    }.value
                    isChecking = false
                    if matches.isEmpty {
                        try install(configuration)
                    } else {
                        pendingConfiguration = configuration
                        overlappingRepositories = matches
                        showingOverlapConfirmation = true
                        status = "Confirmation required"
                    }
                } catch { fail(error) }
            }
        } catch { fail(error) }
    }

    func confirmOverlap() {
        guard let configuration = pendingConfiguration else { return }
        showingOverlapConfirmation = false
        pendingConfiguration = nil
        do { try install(configuration) } catch { fail(error) }
    }

    func cancelOverlap() {
        showingOverlapConfirmation = false
        pendingConfiguration = nil
        overlappingRepositories = []
        status = isRunning ? "Synchronizing" : "Stopped"
    }

    func stop() {
        stopProcess()
        do {
            if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            status = root.isEmpty ? "Not configured" : "Stopped"
        } catch { fail(error) }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func currentConfiguration() -> Configuration {
        Configuration(root: root, machine: machine, peer: peer,
                      remoteRoot: remoteRoot, remoteExecutable: remoteExecutable)
    }

    private func install(_ configuration: Configuration) throws {
        if SMAppService.mainApp.status == .notRegistered {
            try SMAppService.mainApp.register()
        }
        try launch(configuration: configuration)
    }

    private func launch(configuration: Configuration) throws {
        guard syncProcess?.isRunning != true else { return }
        guard let helper = Bundle.main.url(forResource: "git-sync", withExtension: nil) else {
            throw SyncError.invalidConfiguration("The app bundle is missing git-sync. Re-run scripts/install.sh.")
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: configURL, options: .atomic)

        let process = Process(), output = Pipe()
        process.executableURL = helper
        process.arguments = ["run", "--config", configURL.path, "--state", stateURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.appendLogs(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.syncProcess === process else { return }
                output.fileHandleForReading.readabilityHandler = nil
                self.syncProcess = nil
                self.isRunning = false
                self.status = "Stopped"
                if process.terminationStatus != 0 {
                    self.appendLog("git-sync exited with status \(process.terminationStatus)")
                }
            }
        }
        try process.run()
        syncProcess = process
        isRunning = true
        error = nil
        status = SMAppService.mainApp.status == .requiresApproval ? "Synchronizing — login approval required" : "Synchronizing"
        appendLog("Started sync with \(configuration.peer)")
    }

    private func appendLogs(_ data: Data) {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .forEach { appendLog(String($0)) }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }

    private func stopProcess() {
        guard let process = syncProcess else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        syncProcess = nil
        isRunning = false
    }

    func quit() {
        stopProcess()
        NSApplication.shared.terminate(nil)
    }

    private func fail(_ error: Error) {
        isChecking = false
        self.error = String(describing: error)
        status = isRunning ? "Synchronizing" : "Stopped"
        appendLog("Error: \(error)")
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

    private static var defaultMachine: String {
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showingOverlapConfirmation { overlapConfirmation } else { mainContent }
        }
        .frame(width: 460, height: 620)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            Form {
                Section("This Mac") {
                    HStack {
                        TextField("Projects folder", text: $model.root)
                        Button("Choose…", action: model.chooseRoot)
                    }
                    TextField("Machine name", text: $model.machine)
                }
                Section("SSH Peer") {
                    TextField("Host", text: $model.peer)
                    TextField("Projects folder on peer", text: $model.remoteRoot)
                    TextField("git-sync on peer", text: $model.remoteExecutable)
                }
                Section("Status") {
                    Label(model.status, systemImage: model.isRunning ? "arrow.triangle.2.circlepath" : "pause.circle")
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        Button(model.isChecking ? "Checking…" : "Save & Start", action: model.start)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isChecking)
                        Button("Stop", action: model.stop).disabled(!model.isRunning)
                        if model.status.contains("approval") {
                            Button("Login Items…", action: model.openLoginItems)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Transfers").font(.headline)
                if model.logs.isEmpty {
                    Text("No transfer activity yet").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(Array(model.logs.reversed().enumerated()), id: \.offset) {
                        Text($0.element).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .listStyle(.plain)
                }
            }
            .padding(12)
            .frame(height: 210)

            Divider()
            HStack {
                Spacer()
                Button("Quit Git Sync", action: model.quit)
            }
            .padding(10)
        }
    }

    private var overlapConfirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm \(model.overlappingRepositories.count) Matches").font(.title2.bold())
            Text("These repositories exist on both machines. They will be treated as the same repositories; local branches and working files will not be changed.")
            List(model.overlappingRepositories, id: \.self) { Text($0) }
            HStack {
                Button("Cancel", action: model.cancelOverlap)
                Spacer()
                Button("Sync Anyway", action: model.confirmOverlap).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
#else
import Foundation
@main enum GitSyncApp { static func main() { print("Git Sync.app is available on macOS only") } }
#endif
