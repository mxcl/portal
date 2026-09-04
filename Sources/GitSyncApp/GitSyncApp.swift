#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import GitSyncCore
import GitSyncEngine
import GitSyncGraph
import gitdiff

@main
struct GitSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
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
                .disabled(!model.isConfigured || !model.helperAvailable)
            }
        }

        Settings {
            SettingsView(model: model)
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
    @Published var configuration = AppConfiguration(root: "", machine: Configuration.defaultMachine)
    @Published var status = "Starting Sync Helper"
    @Published var error: String?
    @Published var hostError: String?
    @Published var isChecking = false
    @Published var isRunning = false
    @Published var isPaused = false
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
    @Published var selectedCommitDiff: String?
    @Published var commitDiffError: String?
    @Published var isLoadingCommitDiff = false
    @Published var projectSnapshot: RepositorySnapshot?
    @Published var projectReadme: RepositoryReadme?
    @Published var projectGitHubURL: URL?
    @Published var projectError: String?
    @Published var isLoadingProject = false
    @Published var placementInProgress: String?
    @Published var localProjects: [String: PeerProject] = [:]
    @Published var remoteProjects: [UUID: [String: PeerProject]] = [:]
    @Published var checkoutRequest: CheckoutRequest?
    @Published var helperAvailable = false
    @Published var helperError: String?

    fileprivate var hostDraft = HostDraft()
    fileprivate var hostNameDraft = ""

    private let selectedProjectKey = "selected-project-v2"
    private let loginMigrationKey = "migrated-menu-login-item-v1"
    private let loginItem = SMAppService.loginItem(identifier: "dev.mxcl.git-sync.menu")
    private var pendingHostDraft: HostDraft?
    private var notificationObserver: NSObjectProtocol?
    private var fetchingSnapshot = false
    private var snapshotPending = false
    private var connecting = false

    init() {
        if embeddedHelperURL != nil { migrateLegacyLoginItem() }
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: EngineControlProtocol.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleSnapshot() }
        }
        retryHelper()
    }

    deinit {
        if let notificationObserver {
            DistributedNotificationCenter.default().removeObserver(notificationObserver)
        }
    }

    var launchesAtLogin: Bool {
        loginItem.status == .enabled || loginItem.status == .requiresApproval
    }

    var launchAtLoginRequiresApproval: Bool { loginItem.status == .requiresApproval }

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

    var selectedLocalRepositoryURL: URL? {
        guard let name = selectedProjectName, localProjects[name] != nil else { return nil }
        return expandedRoot.appendingPathComponent(name, isDirectory: true)
    }

    func retryHelper() {
        guard !connecting else { return }
        helperAvailable = false
        helperError = nil
        guard embeddedHelperURL != nil else {
            helperError = "The embedded Sync Helper is missing. Reinstall Git Sync."
            return
        }
        connecting = true
        Task {
            defer { connecting = false }
            for attempt in 0..<20 {
                do {
                    let reply = try await EngineClient.send(.snapshot)
                    apply(reply)
                    helperAvailable = true
                    helperError = nil
                    return
                } catch {
                    if (attempt + 1).isMultiple(of: 4) {
                        launchHelper()
                    }
                    if attempt < 19 { try? await Task.sleep(for: .milliseconds(250)) }
                    else { helperError = "Sync Helper unavailable: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func scheduleSnapshot() {
        if fetchingSnapshot {
            snapshotPending = true
            return
        }
        fetchingSnapshot = true
        Task {
            do {
                let reply = try await EngineClient.send(.snapshot)
                apply(reply)
                helperAvailable = true
                helperError = nil
            } catch {
                helperAvailable = false
                helperError = "Sync Helper unavailable: \(error.localizedDescription)"
            }
            fetchingSnapshot = false
            if snapshotPending {
                snapshotPending = false
                scheduleSnapshot()
            }
        }
    }

    private func perform(_ command: EngineCommand, hostCommand: Bool = false,
                         completion: ((EngineReply) -> Void)? = nil) {
        Task {
            do {
                let reply = try await EngineClient.send(command)
                apply(reply)
                helperAvailable = true
                if let message = reply.error {
                    if hostCommand { hostError = message } else { error = message }
                } else {
                    completion?(reply)
                }
            } catch {
                helperAvailable = false
                helperError = "Sync Helper unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ reply: EngineReply) {
        if let snapshot = reply.snapshot { apply(snapshot) }
    }

    private func apply(_ snapshot: EngineSnapshot) {
        let oldLocal = selectedProjectName.flatMap { name in
            configuration.folders.first(where: { $0.name == name })?.availableLocally
        }
        configuration = snapshot.configuration
        status = snapshot.status
        error = snapshot.error
        isChecking = snapshot.isChecking
        isRunning = snapshot.isRunning
        isPaused = snapshot.isPaused
        backupItems = snapshot.backupItems
        backupError = snapshot.backupError
        restoringBackup = snapshot.restoringBackup
        placementInProgress = snapshot.placementInProgress
        localProjects = snapshot.localProjects
        remoteProjects = snapshot.remoteProjects

        let availableNames = Set(configuration.folders.map(\.name)).union(backupItems.map(\.name))
        if selectedProjectName == nil || !availableNames.contains(selectedProjectName!) {
            let saved = UserDefaults.standard.string(forKey: selectedProjectKey)
            let selection = saved.flatMap { availableNames.contains($0) ? $0 : nil }
                ?? projectNames.first ?? archivedProjects.first?.name
            selectProject(selection)
        } else if let name = selectedProjectName {
            let newLocal = configuration.folders.first(where: { $0.name == name })?.availableLocally
            if oldLocal != newLocal { selectProject(name) }
        }
    }

    func chooseRoot() {
        guard configuration.root.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose the folder containing your Git projects"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let root = panel.url?.path else { return }
        perform(.setRoot(root: root, machine: configuration.machine))
    }

    func pause() { perform(.pause) }
    func resume() { perform(.resume) }

    func selectProject(_ name: String?) {
        selectedProjectName = name
        if let name { UserDefaults.standard.set(name, forKey: selectedProjectKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedProjectKey) }
        selectCommit(nil)
        projectSnapshot = nil
        projectReadme = nil
        projectGitHubURL = nil
        projectError = nil
        guard let name else { return }
        let repositoryURL = repositoryURL(for: name)
        guard let repositoryURL else { return }
        isLoadingProject = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let repository = Repository(name: name, url: repositoryURL)
                    return (try repository.snapshot(), repository.readme(), repository.githubURL)
                }.value
                guard selectedProjectName == name else { return }
                projectSnapshot = result.0
                projectReadme = result.1
                projectGitHubURL = result.2
                isLoadingProject = false
            } catch {
                guard selectedProjectName == name else { return }
                isLoadingProject = false
                projectError = String(describing: error)
            }
        }
    }

    func selectCommit(_ oid: String?) {
        selectedCommitID = oid
        selectedCommitDiff = nil
        commitDiffError = nil
        isLoadingCommitDiff = false
        guard let oid, let name = selectedProjectName, let repositoryURL = repositoryURL(for: name) else { return }
        isLoadingCommitDiff = true
        Task {
            do {
                let diff = try await Task.detached(priority: .userInitiated) {
                    try Repository(name: name, url: repositoryURL).diff(at: oid)
                }.value
                guard selectedProjectName == name, selectedCommitID == oid else { return }
                selectedCommitDiff = diff
                isLoadingCommitDiff = false
            } catch {
                guard selectedProjectName == name, selectedCommitID == oid else { return }
                commitDiffError = String(describing: error)
                isLoadingCommitDiff = false
            }
        }
    }

    func openSelectedProjectInTerminal() {
        openSelectedProject(
            with: UTType(importedAs: "com.apple.terminal.shell-script"),
            applicationName: "Terminal"
        )
    }

    func openSelectedProjectInEditor() {
        openSelectedProject(with: .sourceCode, applicationName: "an editor")
    }

    func revealSelectedProjectInFinder() {
        guard let repositoryURL = selectedLocalRepositoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([repositoryURL])
    }

    func openSelectedProjectOnGitHub() {
        guard let projectGitHubURL else { return }
        if !NSWorkspace.shared.open(projectGitHubURL) {
            error = "Couldn’t open the project on GitHub."
        }
    }

    private func openSelectedProject(with contentType: UTType, applicationName: String) {
        guard let repositoryURL = selectedLocalRepositoryURL else { return }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: contentType) else {
            error = "No app is registered as \(applicationName)."
            return
        }
        NSWorkspace.shared.open(
            [repositoryURL], withApplicationAt: applicationURL, configuration: .init()
        ) { [weak self] _, openError in
            guard let openError else { return }
            let message = "Couldn’t open the project in \(applicationName): \(openError.localizedDescription)"
            Task { @MainActor in self?.error = message }
        }
    }

    func placement(of project: String, on hostID: UUID?) -> ProjectPlacement {
        if let hostID { return remoteProjects[hostID]?[project]?.placement ?? .unknown }
        guard let folder = configuration.folders.first(where: { $0.name == project }), folder.availableLocally else {
            return .notPresent
        }
        return localProjects[project]?.placement ?? .unknown
    }

    func checkOut(_ project: String, hostID: UUID?) {
        let preferred: String?
        if let hostID { preferred = remoteProjects[hostID]?[project]?.defaultBranch }
        else { preferred = localProjects[project]?.defaultBranch }
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
        placementInProgress = hostID?.uuidString ?? "local"
        perform(.setPlacement(placement, project: project, hostID: hostID, branch: branch))
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
        guard panel.runModal() == .OK, let root = panel.url?.path else { return }
        perform(.setBackupDestination(root))
    }

    func unarchiveBackup(_ item: BackupItem, snapshot: BackupSnapshot) {
        perform(.restoreBackup(item, snapshot))
    }

    func refreshLocal() { perform(.refresh) }

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
        hostError = nil
        perform(.renameHost(id: selectedHostID, name: hostNameDraft), hostCommand: true) { [weak self] _ in
            self?.showingRenameHost = false
        }
    }

    func addHost() {
        submitHost(hostDraft, allowNameCollisions: false)
    }

    private func submitHost(_ draft: HostDraft, allowNameCollisions: Bool) {
        guard !isChecking else { return }
        hostError = nil
        isChecking = true
        Task {
            do {
                let reply = try await EngineClient.send(.addHost(
                    peer: draft.peer,
                    root: draft.root,
                    executable: draft.executable,
                    allowNameCollisions: allowNameCollisions
                ))
                apply(reply)
                helperAvailable = true
                if let message = reply.error {
                    hostError = "The host was not added. \(message)"
                } else if !reply.nameCollisions.isEmpty {
                    pendingHostDraft = draft
                    overlappingRepositories = reply.nameCollisions
                    showingAddHost = false
                    showingOverlapConfirmation = true
                } else {
                    pendingHostDraft = nil
                    overlappingRepositories = []
                    showingAddHost = false
                    showingOverlapConfirmation = false
                }
            } catch {
                helperAvailable = false
                helperError = "Sync Helper unavailable: \(error.localizedDescription)"
                isChecking = false
            }
        }
    }

    func confirmOverlap() {
        guard let pendingHostDraft else { return }
        showingOverlapConfirmation = false
        submitHost(pendingHostDraft, allowNameCollisions: true)
    }

    func cancelOverlap() {
        showingOverlapConfirmation = false
        pendingHostDraft = nil
        overlappingRepositories = []
    }

    func removeSelectedHost() {
        guard let selectedHostID else { return }
        hostError = nil
        perform(.removeHost(selectedHostID), hostCommand: true) { [weak self] _ in
            self?.selectedHostID = nil
        }
    }

    func chooseBackupHost(_ hostID: UUID) {
        perform(.chooseBackupHost(hostID))
    }

    func setSyncCheckouts(_ enabled: Bool) {
        perform(.setSyncCheckouts(enabled))
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        Task {
            do {
                if enabled {
                    if !launchesAtLogin {
                        await stopRunningHelpers()
                        try loginItem.register()
                    }
                    retryHelper()
                } else {
                    if launchesAtLogin {
                        _ = try? await EngineClient.send(.prepareForTermination)
                        try await loginItem.unregister()
                    }
                    retryHelper()
                }
                objectWillChange.send()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var expandedRoot: URL {
        URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath).standardizedFileURL
    }

    private func repositoryURL(for name: String) -> URL? {
        if configuration.folders.first(where: { $0.name == name })?.availableLocally == true {
            return expandedRoot.appendingPathComponent(name, isDirectory: true)
        }
        guard let destination = configuration.backupDestination else { return nil }
        let url = URL(fileURLWithPath: destination.root).appendingPathComponent("\(name).git", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var embeddedHelperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Git Sync Menu.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    private func launchHelper() -> Bool {
        guard let embeddedHelperURL else { return false }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.mxcl.git-sync.menu"
        ).isEmpty else { return true }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: embeddedHelperURL, configuration: configuration)
        return true
    }

    private func stopRunningHelpers() async {
        _ = try? await EngineClient.send(.prepareForTermination)
        let helpers = NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.mxcl.git-sync.menu"
        )
        helpers.forEach { $0.terminate() }
        for _ in 0..<20 {
            if helpers.allSatisfy(\.isTerminated) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        helpers.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    private func migrateLegacyLoginItem() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: loginMigrationKey) else { return }
        let legacyEnabled = SMAppService.mainApp.status == .enabled
            || SMAppService.mainApp.status == .requiresApproval
        if legacyEnabled && !launchesAtLogin { try? loginItem.register() }
        if legacyEnabled { try? SMAppService.mainApp.unregister() }
        defaults.set(true, forKey: loginMigrationKey)
    }
}


struct ProjectBrowserView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
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
        .overlay {
            if !model.helperAvailable {
                HelperUnavailableView(model: model)
            }
        }
        .onAppear {
            if model.selectedProjectName == nil { model.selectProject(model.projectNames.first) }
        }
        .sheet(item: $model.checkoutRequest) { request in
            BranchPicker(request: request, model: model)
        }
        .onOpenURL { url in
            if url.scheme == "gitsync", url.host == "settings" {
                openSettings()
                NSApplication.shared.activate()
            }
        }
    }
}

private struct HelperUnavailableView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ContentUnavailableView {
                Label("Sync Helper Unavailable", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
            } description: {
                Text(model.helperError ?? "Starting the embedded Sync Helper…")
            } actions: {
                Button("Retry", action: model.retryHelper)
            }
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
                CommitList(snapshot: snapshot, selection: Binding(
                    get: { model.selectedCommitID }, set: model.selectCommit
                ))
            } else {
                ContentUnavailableView("Not on This Mac", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Bring this project to this Mac to render its Git tree and README."))
            }
        }
        .navigationTitle(model.selectedProjectName ?? "Git Tree")
        .toolbar {
            ToolbarItem {
                Button("Show Project Details", systemImage: "info.circle") { model.selectCommit(nil) }
                    .disabled(model.selectedProjectName == nil || model.selectedCommitID == nil)
            }
            ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { model.selectProject(model.selectedProjectName) } }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                ControlGroup {
                    Button("Reveal in Finder", systemImage: "folder", action: model.revealSelectedProjectInFinder)
                    Button("Open in Editor", systemImage: "curlybraces", action: model.openSelectedProjectInEditor)
                    Button("Open in Terminal", systemImage: "terminal", action: model.openSelectedProjectInTerminal)
                    if model.projectGitHubURL != nil {
                        Button("Open on GitHub", systemImage: "arrow.up.right.square",
                               action: model.openSelectedProjectOnGitHub)
                    }
                }
                .disabled(model.selectedLocalRepositoryURL == nil)
            }
        }
    }
}

private struct CommitList: View {
    let snapshot: RepositorySnapshot
    @Binding var selection: String?
    private let graph: CommitGraphModel

    init(snapshot: RepositorySnapshot, selection: Binding<String?>) {
        self.snapshot = snapshot
        _selection = selection
        let headOID = snapshot.head.flatMap { head in
            snapshot.references.first { $0.fullName == "refs/heads/\(head)" }?.oid
        }
        graph = CommitGraphGenerator.generate(commits: snapshot.commits, headOID: headOID)
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(snapshot.commits.indices, id: \.self) { index in
                let commit = snapshot.commits[index]
                CommitRow(commit: commit,
                          references: snapshot.references.filter { $0.oid == commit.oid },
                          graph: graph,
                          rowIndex: index)
                    .listRowSeparator(.hidden)
                    .tag(commit.oid)
            }
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
    let graph: CommitGraphModel
    let rowIndex: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BranchGraphRowCanvas(model: graph, rowIndex: rowIndex, commitOID: commit.oid)
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
                    CopyableCommitSHA(sha: commit.oid)
                    Spacer()
                    Text(commit.date, style: .relative)
                        .monospacedDigit()
                }
                .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, BranchGraphRowCanvas.graphWidth(model: graph, commitOID: commit.oid) + 8)
                .offset(y: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CopyableCommitSHA: View {
    let sha: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 3) {
            Text(sha.prefix(8))
                .monospaced()
            Button("Copy commit SHA", systemImage: "doc.on.doc", action: copy)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption2)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(isHovered ? Color.secondary.opacity(0.18) : .clear, in: Capsule())
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .help("Copy full commit SHA")
        .accessibilityAction(named: "Copy commit SHA", copy)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sha, forType: .string)
    }
}

private struct ProjectDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let name = model.selectedProjectName {
            if let commitID = model.selectedCommitID,
               let commit = model.projectSnapshot?.commits.first(where: { $0.oid == commitID }) {
                CommitDetail(commit: commit,
                             references: model.projectSnapshot?.references.filter { $0.oid == commitID } ?? [],
                             diff: model.selectedCommitDiff,
                             isLoadingDiff: model.isLoadingCommitDiff,
                             error: model.commitDiffError)
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
    let diff: String?
    let isLoadingDiff: Bool
    let error: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(commit.message).font(.headline).textSelection(.enabled)
                    LabeledContent("Author", value: commit.author)
                    LabeledContent("Date") { Text(commit.date.formatted(date: .long, time: .standard)) }
                    LabeledContent("SHA") { Text(commit.oid).monospaced().textSelection(.enabled) }
                    if !commit.parents.isEmpty {
                        LabeledContent("Parents") {
                            VStack(alignment: .trailing) {
                                ForEach(commit.parents, id: \.self) { Text($0).monospaced() }
                            }
                        }
                    }
                    if !references.isEmpty {
                        LabeledContent("References", value: references.map(\.name).joined(separator: ", "))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                if isLoadingDiff {
                    ProgressView("Reading commit diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Couldn’t Read Diff", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let diff {
                    DiffRenderer(diffText: diff)
                        .diffConfiguration(.codeReview.with(theme: colorScheme == .dark ? .dark : .light))
                        .scrollDisabled(true)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
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
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
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

private struct MarkdownBlock {
    enum Kind { case heading1, heading2, heading3, list, code, paragraph, space }
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
                    if model.launchAtLoginRequiresApproval {
                        Button("Open Login Items…", action: model.openLoginItems)
                    }
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
        .overlay {
            if !model.helperAvailable {
                HelperUnavailableView(model: model)
            }
        }
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
