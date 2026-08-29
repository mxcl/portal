#if os(macOS)
import AppKit
import SwiftUI
import GitSyncCore

@main
struct GitSyncApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Git Sync") { ContentView(model: model) }
            .defaultSize(width: 560, height: 460)
        Settings { ContentView(model: model) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var root = ""
    @Published var machine = AppModel.defaultMachine
    @Published var peer = ""
    @Published var remoteRoot = ""
    @Published var remoteExecutable = "git-sync"
    @Published var status = "Not configured"
    @Published var error: String?
    @Published var isChecking = false
    @Published var overlappingRepositories: [String] = []
    @Published var showingOverlapConfirmation = false

    private let label = "dev.mxcl.git-sync"
    private let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GitSync", isDirectory: true)
    private var configURL: URL { support.appendingPathComponent("config.json") }
    private var stateURL: URL { support.appendingPathComponent("state.json") }
    private var logURL: URL { support.appendingPathComponent("git-sync.log") }
    private var agentURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    private var pendingConfiguration: Configuration?

    init() {
        if let config = try? Configuration.load(configURL) {
            root = config.root; machine = config.machine; peer = config.peer
            remoteRoot = config.remoteRoot; remoteExecutable = config.remoteExecutable
        }
        refreshStatus()
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
            let configuration = Configuration(root: root, machine: machine, peer: peer,
                                              remoteRoot: remoteRoot, remoteExecutable: remoteExecutable)
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
        refreshStatus()
    }

    private func install(_ configuration: Configuration) throws {
        guard let helper = Bundle.main.url(forResource: "git-sync", withExtension: nil) else {
            throw SyncError.invalidConfiguration("The app bundle is missing git-sync. Re-run scripts/install.sh.")
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: configURL, options: .atomic)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helper.path, "run", "--config", configURL.path, "--state", stateURL.path],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "EnvironmentVariables": ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        guard runLaunchctl(["bootstrap", "gui/\(getuid())", agentURL.path]) == 0 else {
            throw SyncError.invalidConfiguration("launchd could not start the sync agent. See \(logURL.path)")
        }
        error = nil; refreshStatus()
    }

    private func fail(_ error: Error) {
        isChecking = false
        self.error = String(describing: error)
        status = "Stopped"
    }

    func stop() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        refreshStatus()
    }

    func refreshStatus() {
        status = runLaunchctl(["print", "gui/\(getuid())/\(label)"]) == 0 ? "Synchronizing" : (root.isEmpty ? "Not configured" : "Stopped")
    }

    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }

    private static var defaultMachine: String {
        ProcessInfo.processInfo.hostName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            Form {
                Section("This Mac") {
                    HStack {
                        TextField("Projects folder", text: $model.root)
                        Button("Choose…", action: model.chooseRoot)
                    }
                    TextField("Machine name", text: $model.machine)
                }
                Section("SSH Peer") {
                    TextField("Host (for example linux or max@linux)", text: $model.peer)
                    TextField("Projects folder on peer", text: $model.remoteRoot)
                    TextField("git-sync executable on peer", text: $model.remoteExecutable)
                }
                Section("Status") {
                    Label(model.status, systemImage: model.status == "Synchronizing" ? "checkmark.circle.fill" : "pause.circle")
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    HStack {
                        Button(model.isChecking ? "Checking…" : "Save & Start", action: model.start)
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.isChecking)
                        Button("Stop", action: model.stop)
                        Button("Refresh", action: model.refreshStatus)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(minWidth: 480, minHeight: 400)
        .sheet(isPresented: $model.showingOverlapConfirmation) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text("These repositories exist on both machines. They will be treated as the same repositories; local branches and working files will not be changed.")
                    List(model.overlappingRepositories, id: \.self) { Text($0) }
                }
                .padding()
                .navigationTitle("Confirm \(model.overlappingRepositories.count) Matches")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: model.cancelOverlap)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sync Anyway", action: model.confirmOverlap)
                    }
                }
            }
            .frame(minWidth: 480, minHeight: 360)
        }
    }
}
#else
import Foundation
@main enum GitSyncApp { static func main() { print("Git Sync.app is available on macOS only") } }
#endif
