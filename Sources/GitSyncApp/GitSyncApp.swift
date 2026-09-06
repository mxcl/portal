#if os(macOS)
import AppKit
import ServiceManagement
import SwiftUI
import Textual
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
        Window("Gitinuum", id: "projects") {
            ProjectBrowserView(model: model)
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appSettings) {
                Button("Install Command Line Tool…") {
                    guard let script = Bundle.main.url(forResource: "install-gitinuum", withExtension: "command"),
                          NSWorkspace.shared.open(script) else {
                        let alert = NSAlert()
                        alert.messageText = "Could not open the command line installer"
                        alert.informativeText = "Reinstall Gitinuum and try again."
                        alert.runModal()
                        return
                    }
                }
            }
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

fileprivate enum ProjectSource: Hashable, Identifiable, Sendable {
    case local
    case host(UUID)
    case backup(String)

    var id: String {
        switch self {
        case .local: "local"
        case .host(let id): "host-\(id)"
        case .backup(let id): "backup-\(id)"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = AppConfiguration(root: "", machine: Configuration.defaultMachine)
    @Published var globalShortcutEnabled = true
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
    @Published fileprivate var projectSource: ProjectSource? {
        didSet { updateRepositoryWatcher() }
    }
    @Published var placementInProgress: String?
    @Published var localProjects: [String: PeerProject] = [:]
    @Published var remoteProjects: [UUID: [String: PeerProject]] = [:]
    @Published var checkoutRequest: CheckoutRequest?
    @Published var helperAvailable = false
    @Published var helperError: String?

    fileprivate var hostDraft = HostDraft()
    fileprivate var hostNameDraft = ""

    private let selectedProjectKey = "selected-project-v2"
    private let loginMigrationKey = "migrated-menu-helper-login-item-v5"
    private let loginItem = SMAppService.loginItem(identifier: "dev.mxcl.git-sync.menu-helper")
    private var pendingHostDraft: HostDraft?
    private var notificationObserver: NSObjectProtocol?
    private var fetchingSnapshot = false
    private var snapshotPending = false
    private var connecting = false
    private var projectLoadGeneration = 0
    private var diffLoadGeneration = 0
    private var repositoryWatcher: RepositoryWatcher?
    private var watchedRepositoryURL: URL?
    private var watcherSetup: Task<Void, Never>?
    private var projectRefreshPending = false

    init(connectToHelper: Bool = true) {
        guard connectToHelper else { return }
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
        watcherSetup?.cancel()
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

    func backupStatus(for project: String) -> (title: String, symbol: String, detail: String) {
        guard configuration.backup != nil || configuration.backupDestination != nil else {
            return ("Backup not configured", "externaldrive", "Choose a backup destination in Settings.")
        }
        if let error = backupError ?? helperError {
            return ("Backup status unavailable", "exclamationmark.triangle", error)
        }
        guard let item = backupItems.first(where: { $0.name == project }), !item.snapshots.isEmpty else {
            return ("No backup found", "externaldrive", "No stored snapshot is currently listed for this project.")
        }
        return ("Backup available", "externaldrive.badge.checkmark",
                "Stored snapshots from: \(item.snapshots.map(\.machine).joined(separator: ", ")).")
    }

    var selectedLocalRepositoryURL: URL? {
        guard let name = selectedProjectName else { return nil }
        return repositoryURL(for: name)
    }

    fileprivate var projectSources: [ProjectSource] {
        guard let name = selectedProjectName else { return [] }
        return sources(for: name)
    }

    fileprivate func projectSourceLabel(_ source: ProjectSource) -> String {
        switch source {
        case .local:
            return "This Mac"
        case .host(let id):
            return configuration.hosts.first(where: { $0.id == id })?.name ?? "Unavailable Host"
        case .backup(let id):
            let snapshot = backupItems.first(where: { $0.name == selectedProjectName })?
                .snapshots.first(where: { $0.id == id })
            return "Backup — \(snapshot?.machine ?? id)"
        }
    }

    fileprivate func projectSourceSymbol(_ source: ProjectSource) -> String {
        if case .backup = source { return "archivebox" }
        return "desktopcomputer"
    }

    func retryHelper() {
        guard !connecting else { return }
        helperAvailable = false
        helperError = nil
        guard embeddedHelperURL != nil else {
            helperError = "The embedded Sync Helper is missing. Reinstall Gitinuum."
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

    func apply(_ snapshot: EngineSnapshot) {
        let oldLocal = selectedProjectName.flatMap { name in
            configuration.folders.first(where: { $0.name == name })?.availableLocally
        }
        let oldSource = projectSource
        configuration = snapshot.configuration
        globalShortcutEnabled = snapshot.globalShortcutEnabled
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
            if oldLocal != newLocal || oldSource.map({ !sources(for: name).contains($0) }) == true
                || oldSource == nil && !sources(for: name).isEmpty {
                loadProject(name, from: sources(for: name))
            }
        }
        updateRepositoryWatcher()
    }

    private func updateRepositoryWatcher() {
        let url = projectSource == .local && placementInProgress != "local" ? selectedLocalRepositoryURL : nil
        guard url != watchedRepositoryURL else { return }
        watcherSetup?.cancel()
        repositoryWatcher = nil
        watchedRepositoryURL = url
        projectRefreshPending = false
        guard let url else { return }
        watcherSetup = Task { [weak self] in
            do {
                let paths = try await Task.detached { try RepositoryWatcher.paths(for: url) }.value
                guard !Task.isCancelled, let self, watchedRepositoryURL == url else { return }
                repositoryWatcher = try RepositoryWatcher(paths: paths) { [weak self] in
                    guard let self, watchedRepositoryURL == url, projectSource == .local else { return }
                    if isLoadingProject { projectRefreshPending = true }
                    else { refreshProject() }
                }
            } catch {
                guard !Task.isCancelled, let self, watchedRepositoryURL == url else { return }
                projectError = "Automatic refresh unavailable: \(error.localizedDescription)"
            }
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

    @discardableResult
    func openProjectURL(_ url: URL) -> Bool {
        guard url.scheme == "gitsync", url.host == "project",
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        selectProject(name)
        return true
    }

    func selectProject(_ name: String?) {
        guard name != selectedProjectName else { return }
        selectedProjectName = name
        if let name { UserDefaults.standard.set(name, forKey: selectedProjectKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedProjectKey) }
        selectCommit(nil)
        projectSnapshot = nil
        projectReadme = nil
        projectGitHubURL = nil
        projectError = nil
        projectSource = nil
        projectLoadGeneration += 1
        isLoadingProject = false
        guard let name else { return }
        loadProject(name, from: sources(for: name))
    }

    func refreshProject() {
        guard let name = selectedProjectName else { return }
        loadProject(name, from: projectSource.map { [$0] } ?? sources(for: name))
    }

    fileprivate func selectProjectSource(_ source: ProjectSource) {
        guard source != projectSource, let name = selectedProjectName else { return }
        selectCommit(nil)
        projectSnapshot = nil
        projectReadme = nil
        projectGitHubURL = nil
        projectError = nil
        projectSource = source
        loadProject(name, from: [source])
    }

    private func loadProject(_ name: String, from sources: [ProjectSource]) {
        projectLoadGeneration += 1
        let generation = projectLoadGeneration
        guard let first = sources.first else {
            projectSource = nil
            isLoadingProject = false
            return
        }
        projectSource = first
        projectError = nil
        isLoadingProject = true
        let configuration = configuration
        Task {
            defer {
                if generation == projectLoadGeneration, projectRefreshPending {
                    projectRefreshPending = false
                    refreshProject()
                }
            }
            var lastError: Error?
            for source in sources {
                do {
                    let content = try await Task.detached(priority: .userInitiated) {
                        try Self.content(for: name, source: source, configuration: configuration)
                    }.value
                    guard generation == projectLoadGeneration, selectedProjectName == name else { return }
                    projectSource = source
                    projectError = nil
                    projectSnapshot = content.snapshot
                    projectReadme = content.readme
                    projectGitHubURL = content.githubURL
                    isLoadingProject = false
                    if let oid = selectedCommitID, selectedCommitDiff == nil {
                        selectCommit(oid)
                    }
                    return
                } catch {
                    lastError = error
                }
            }
            guard generation == projectLoadGeneration, selectedProjectName == name else { return }
            isLoadingProject = false
            projectError = lastError.map(String.init(describing:)) ?? "No project source is available."
        }
    }

    func selectCommit(_ oid: String?) {
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        selectedCommitID = oid
        selectedCommitDiff = nil
        commitDiffError = nil
        isLoadingCommitDiff = false
        guard let oid, let name = selectedProjectName, let source = projectSource else { return }
        isLoadingCommitDiff = true
        let configuration = configuration
        Task {
            do {
                let diff = try await Task.detached(priority: .userInitiated) {
                    try Self.diff(for: name, oid: oid, source: source, configuration: configuration)
                }.value
                guard generation == diffLoadGeneration, selectedProjectName == name,
                      selectedCommitID == oid, projectSource == source else { return }
                selectedCommitDiff = diff
                isLoadingCommitDiff = false
            } catch {
                guard generation == diffLoadGeneration, selectedProjectName == name,
                      selectedCommitID == oid, projectSource == source else { return }
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
        updateRepositoryWatcher()
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

    func setGlobalShortcutEnabled(_ enabled: Bool) {
        perform(.setGlobalShortcutEnabled(enabled))
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
                UserDefaults.standard.set(enabled, forKey: "launch-at-login")
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
        guard configuration.folders.first(where: { $0.name == name })?.availableLocally == true else { return nil }
        return expandedRoot.appendingPathComponent(name, isDirectory: true)
    }

    private func sources(for name: String) -> [ProjectSource] {
        if repositoryURL(for: name) != nil { return [.local] }
        let live = configuration.folders.first(where: { $0.name == name }).map { folder in
            configuration.hosts.filter { folder.availableHosts.contains($0.id) }.map { ProjectSource.host($0.id) }
        } ?? []
        let backups = backupItems.first(where: { $0.name == name })?.snapshots.map {
            ProjectSource.backup($0.id)
        } ?? []
        return live + backups
    }

    private nonisolated static func content(for name: String, source: ProjectSource,
                                            configuration: AppConfiguration) throws -> RepositoryContent {
        switch source {
        case .local:
            let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
            return try Repository(name: name, url: root.appendingPathComponent(name)).content()
        case .host(let id):
            guard let host = configuration.hosts.first(where: { $0.id == id }) else {
                throw SyncError.invalidConfiguration("The selected host is no longer configured.")
            }
            return try Runner.projectContent(name, configuration: remoteConfiguration(host, in: configuration))
        case .backup(let snapshotID):
            if let root = try configuration.validatedBackupDestination() {
                return try BackupIndex.content(name, snapshotID: snapshotID, from: root)
            }
            guard let host = try configuration.backupHost() else {
                throw SyncError.invalidConfiguration("The backup destination is unavailable.")
            }
            return try Runner.backupContent(name, snapshotID: snapshotID,
                                            configuration: remoteConfiguration(host, in: configuration,
                                                                               receiveOnly: true))
        }
    }

    private nonisolated static func diff(for name: String, oid: String, source: ProjectSource,
                                         configuration: AppConfiguration) throws -> String {
        switch source {
        case .local:
            let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
            return try Repository(name: name, url: root.appendingPathComponent(name)).diff(at: oid)
        case .host(let id):
            guard let host = configuration.hosts.first(where: { $0.id == id }) else {
                throw SyncError.invalidConfiguration("The selected host is no longer configured.")
            }
            return try Runner.projectDiff(name, oid: oid,
                                          configuration: remoteConfiguration(host, in: configuration))
        case .backup(let snapshotID):
            if let root = try configuration.validatedBackupDestination() {
                return try BackupIndex.diff(name, snapshotID: snapshotID, oid: oid, from: root)
            }
            guard let host = try configuration.backupHost() else {
                throw SyncError.invalidConfiguration("The backup destination is unavailable.")
            }
            return try Runner.backupDiff(name, snapshotID: snapshotID, oid: oid,
                                         configuration: remoteConfiguration(host, in: configuration,
                                                                            receiveOnly: true))
        }
    }

    private nonisolated static func remoteConfiguration(_ host: SyncHost, in app: AppConfiguration,
                                                        receiveOnly: Bool = false) -> Configuration {
        Configuration(root: app.root, machine: app.machine, peer: host.peer,
                      remoteRoot: receiveOnly ? "" : host.root, remoteExecutable: host.executable,
                      remoteMachine: host.machine, remoteReceiveOnly: receiveOnly ? true : nil)
    }

    private var embeddedHelperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/Gitinuum Menu Helper.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    private func launchHelper() -> Bool {
        guard let embeddedHelperURL else { return false }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.mxcl.git-sync.menu-helper"
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
            withBundleIdentifier: "dev.mxcl.git-sync.menu-helper"
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
        let oldHelper = SMAppService.loginItem(identifier: "dev.mxcl.git-sync.menu")
        let oldHelperEnabled = oldHelper.status == .enabled || oldHelper.status == .requiresApproval
        do {
            if oldHelperEnabled { try oldHelper.unregister() }
            if (legacyEnabled || oldHelperEnabled || defaults.bool(forKey: "launch-at-login")) && !launchesAtLogin { try loginItem.register() }
            if legacyEnabled { try SMAppService.mainApp.unregister() }
            defaults.set(true, forKey: loginMigrationKey)
        } catch {
            self.error = "Could not update the login helper: \(error.localizedDescription)"
        }
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
            List(selection: Binding(get: { model.selectedProjectName }, set: { name in
                if let name { model.selectProject(name) }
            })) {
                ForEach(projects, id: \.self) { name in
                    ProjectRow(name: name, model: model).tag(name)
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
            } else if model.openProjectURL(url) {
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
            } else if model.isLoadingProject && model.projectSnapshot == nil {
                ProgressView("Reading Git history…")
            } else if let error = model.projectError {
                ContentUnavailableView {
                    Label("Couldn’t Read Git History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again", action: model.refreshProject)
                }
            } else if let snapshot = model.projectSnapshot {
                CommitList(snapshot: snapshot, hosts: model.configuration.hosts, selection: Binding(
                    get: { model.selectedCommitID }, set: model.selectCommit
                ))
            } else {
                ContentUnavailableView("No Available Copy", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Bring this project to a configured host to render its Git tree and README."))
            }
        }
        .navigationTitle(model.selectedProjectName ?? "Git Tree")
        .toolbar {
            if let source = model.projectSource, source != .local {
                ToolbarItem {
                    Picker("Git tree source", selection: Binding(
                        get: { source }, set: model.selectProjectSource
                    )) {
                        ForEach(model.projectSources) { option in
                            Label(model.projectSourceLabel(option),
                                  systemImage: model.projectSourceSymbol(option)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .disabled(model.projectSources.count < 2)
                    .accessibilityLabel("Git tree source")
                    .help("Git tree source: \(model.projectSourceLabel(source))")
                }
                ToolbarSpacer(.fixed)
            }
            ToolbarItem {
                ControlGroup {
                    Button("Reveal in Finder", systemImage: "folder", action: model.revealSelectedProjectInFinder)
                        .help("Reveal project in Finder")
                        .disabled(model.selectedLocalRepositoryURL == nil)
                    Button("Open in Editor", systemImage: "curlybraces", action: model.openSelectedProjectInEditor)
                        .help("Open project in the default editor")
                        .disabled(model.selectedLocalRepositoryURL == nil)
                    Button("Open in Terminal", systemImage: "terminal", action: model.openSelectedProjectInTerminal)
                        .help("Open project in the default terminal")
                        .disabled(model.selectedLocalRepositoryURL == nil)
                    Button("Open on GitHub", systemImage: "arrow.up.right.square",
                           action: model.openSelectedProjectOnGitHub)
                        .disabled(model.projectGitHubURL == nil)
                        .help("Open project on GitHub")
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("Show Project Details", systemImage: "info.circle") { model.selectCommit(nil) }
                    .disabled(model.selectedProjectName == nil || model.selectedCommitID == nil)
                    .help("Show project details")
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refreshProject)
                    .help("Refresh project")
            }
        }
    }
}

private struct CommitList: View {
    let snapshot: RepositorySnapshot
    let hosts: [SyncHost]
    @Binding var selection: String?
    private let graph: CommitGraphModel
    private var hasWorkingChanges: Bool { snapshot.workingChanges?.isEmpty == false }

    init(snapshot: RepositorySnapshot, hosts: [SyncHost], selection: Binding<String?>) {
        self.snapshot = snapshot
        self.hosts = hosts
        _selection = selection
        let headOID = snapshot.headOID ?? snapshot.head.flatMap { head in
            snapshot.references.first { $0.fullName == "refs/heads/\(head)" }?.oid
        }
        graph = CommitGraphGenerator.generate(commits: snapshot.commits, headOID: headOID,
                                              hasWorkingChanges: snapshot.workingChanges?.isEmpty == false)
    }

    var body: some View {
        List(selection: $selection) {
            if hasWorkingChanges, let changes = snapshot.workingChanges {
                HStack(alignment: .top, spacing: 8) {
                    BranchGraphRowCanvas(model: graph, rowIndex: 0,
                                         commitOID: CommitGraphGenerator.workingChangesID)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Uncommitted changes").lineLimit(1)
                        Text(changes.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(changes.summary)
                .accessibilityElement(children: .combine)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            }
            ForEach(snapshot.commits.indices, id: \.self) { index in
                let commit = snapshot.commits[index]
                CommitRow(commit: commit,
                          references: snapshot.references.filter { $0.oid == commit.oid },
                          hosts: hosts,
                          graph: graph,
                          rowIndex: index + (hasWorkingChanges ? 1 : 0))
                    .listRowSeparator(.hidden)
                    .tag(commit.oid)
            }
        }
        .overlay {
            if snapshot.commits.isEmpty && !hasWorkingChanges {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }
}

private struct CommitRow: View {
    let commit: RepositoryCommit
    let references: [RepositoryReference]
    let hosts: [SyncHost]
    let graph: CommitGraphModel
    let rowIndex: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BranchGraphRowCanvas(model: graph, rowIndex: rowIndex, commitOID: commit.oid)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(commit.subject).lineLimit(1)
                    ForEach(references.prefix(4)) { reference in
                        Text(reference.displayName(hosts: hosts))
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
                             hosts: model.configuration.hosts,
                             source: model.projectSource.map(model.projectSourceLabel),
                             diff: model.selectedCommitDiff,
                             isLoadingDiff: model.isLoadingCommitDiff,
                             error: model.commitDiffError)
                    .id(commit.oid)
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
                VStack(alignment: .leading) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(name).font(.title2.bold())
                            Spacer()
                            backupStatus
                        }
                        VStack(alignment: .leading) {
                            Text(name).font(.title2.bold())
                            backupStatus
                        }
                    }
                    if let source = model.projectSource, source != .local {
                        Text("From \(model.projectSourceLabel(source))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let archived = model.archivedProjects.first(where: { $0.name == name }) {
                    ArchivedProjectControls(item: archived, model: model)
                } else {
                    HostControls(project: name, model: model)
                }
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
                    Text("Project details and README are unavailable from the selected source.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle(name)
    }

    private var backupStatus: some View {
        let backup = model.backupStatus(for: name)
        return Label(backup.title, systemImage: backup.symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(backup.detail)
            .accessibilityHint(backup.detail)
    }
}

private struct HostControls: View {
    let project: String
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { placements }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading) { placements }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hosts")
    }

    private var placements: some View {
        let canArchive = model.configuration.backup != nil || model.configuration.backupDestination != nil
        return Group {
            PlacementRow(project: project, name: model.configuration.machine,
                         placement: model.placement(of: project, on: nil), canArchive: canArchive,
                         progress: model.placementInProgress == "local") {
                $0 == .checkedOut ? model.checkOut(project, hostID: nil)
                    : model.setPlacement($0, project: project, hostID: nil)
            }
            ForEach(model.configuration.hosts) { host in
                PlacementRow(project: project, name: host.name,
                             placement: model.placement(of: project, on: host.id), canArchive: canArchive,
                             progress: model.placementInProgress == host.id.uuidString) {
                    $0 == .checkedOut ? model.checkOut(project, hostID: host.id)
                        : model.setPlacement($0, project: project, hostID: host.id)
                }
            }
        }
    }
}

private struct PlacementRow: View {
    let project: String
    let name: String
    let placement: ProjectPlacement
    let canArchive: Bool
    let progress: Bool
    let change: (ProjectPlacement) -> Void
    @State private var showingArchiveConfirmation = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Menu {
                    switch placement {
                    case .checkedOut:
                        if canArchive {
                            Button("Archive…", role: .destructive) { showingArchiveConfirmation = true }
                        }
                    case .mirrored:
                        Button("Check Out") { change(.checkedOut) }
                        Button("Move Repository to Trash", role: .destructive) { change(.notPresent) }
                    case .notPresent:
                        Button("Mirror on This Host") { change(.mirrored) }
                    case .unknown:
                        Text("Host unavailable")
                    }
                } label: {
                    Label(name, systemImage: "desktopcomputer")
                        .fontWeight(.medium)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(name)
                .accessibilityValue(progress ? "Updating, \(placement.title)" : placement.title)
                .disabled(progress || placement == .unknown || placement == .checkedOut && !canArchive)
                .alert("Archive \(project)?", isPresented: $showingArchiveConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Archive", role: .destructive) { change(.notPresent) }
                } message: {
                    Text("The checkout on \(name) will be moved to Trash. The backup will remain available to restore.")
                }
                if progress { ProgressView().controlSize(.small).accessibilityLabel("Updating \(name)") }
            }
            Label(placement.title, systemImage: placement.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.trailing)
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
    let hosts: [SyncHost]
    let source: String?
    let diff: String?
    let isLoadingDiff: Bool
    let error: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var files: [DiffFile] = []
    @State private var visibleFiles: Set<UUID> = []
    @State private var isParsingDiff = false

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(commit.message).font(.headline).textSelection(.enabled)
                            if let source { LabeledContent("Source", value: source) }
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
                                LabeledContent("References", value: references.map { $0.displayName(hosts: hosts) }.joined(separator: ", "))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        if isLoadingDiff || isParsingDiff {
                            ProgressView("Reading commit diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let error {
                            ContentUnavailableView("Couldn’t Read Diff", systemImage: "exclamationmark.triangle",
                                                   description: Text(error))
                        } else if diff != nil, !files.isEmpty {
                            VStack(spacing: 16) {
                                ForEach(files) { file in
                                    DiffFileView(file: file)
                                        .id(file.id)
                                        .onGeometryChange(for: Bool.self) { geometry in
                                            CommitFileNavigator.isVisible(geometry.frame(in: .named("commitViewport")),
                                                                          viewportHeight: viewport.size.height)
                                        } action: { visible in
                                            if visible { visibleFiles.insert(file.id) }
                                            else { visibleFiles.remove(file.id) }
                                        }
                                }
                            }
                            .diffConfiguration(.codeReview.with(theme: colorScheme == .dark ? .dark : .light))
                            .padding()
                        } else {
                            ContentUnavailableView("No Diff", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
                .coordinateSpace(name: "commitViewport")
                .toolbar {
                    if !isLoadingDiff, error == nil, !files.isEmpty, visibleFiles.count < files.count {
                        ToolbarSpacer(.flexible, placement: .primaryAction)
                        ToolbarItem(placement: .primaryAction) {
                            CommitFileNavigator(files: files, visibleFiles: visibleFiles) { id in
                                scroll.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(commit.subject)
        .task(id: diff) {
            files = []
            visibleFiles = []
            isParsingDiff = false
            guard let diff else { return }
            isParsingDiff = true
            let parsed = try? await UnifiedDiffParser().parse(diff)
            guard !Task.isCancelled else { return }
            files = parsed ?? []
            isParsingDiff = false
        }
    }
}

private struct ArchivedProjectControls: View {
    let item: BackupItem
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Archived", systemImage: "archivebox.fill").font(.headline)
            Text("This project has no active checkout or mirror. Its repository is stored only at the backup destination.")
                .foregroundStyle(.secondary)
            if let source = model.projectSource {
                Label(model.projectSourceLabel(source), systemImage: model.projectSourceSymbol(source))
                    .foregroundStyle(.secondary)
            }
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
        }
    }
}

private struct MarkdownDocument: View {
    let markdown: String

    var body: some View {
        StructuredText(markdown: markdown)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
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
                    Toggle("Launch Gitinuum at login", isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchAtLogin))
                    if model.launchAtLoginRequiresApproval {
                        Button("Open Login Items…", action: model.openLoginItems)
                    }
                }
                Section("Keyboard Shortcut") {
                    Toggle("Open Gitinuum with ⌘⌥`", isOn: Binding(
                        get: { model.globalShortcutEnabled }, set: model.setGlobalShortcutEnabled
                    ))
                    Text("Available from any app while the menu bar helper is running.")
                        .foregroundStyle(.secondary)
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
            Text("This changes how the host appears in Gitinuum, not its Git identity.")
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
                TextField("gitinuumd executable", text: $model.hostDraft.executable)
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
@main enum GitSyncApp { static func main() { print("Gitinuum.app is available on macOS only") } }
#endif
