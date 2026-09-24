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
                .onAppear { appDelegate.editor = model.editor }
                .modifier(EditorCloseGuard(editor: model.editor))
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            EditorCommands(editor: model.editor)
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
                ForEach(model.availableTabs) { tab in
                    Button("Show \(tab.title)") { model.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(tab.rawValue.first!), modifiers: [.command, .option])
                }
                Divider()
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
    weak var editor: ProjectEditor?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor?.confirmDiscard() == false ? .terminateCancel : .terminateNow
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

enum ProjectSource: Hashable, Identifiable, Sendable {
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

struct ProjectStaging: Identifiable {
    let id: String
    let source: ProjectSource
    let host: String
    let snapshot: RepositorySnapshot

    var headOID: String? {
        snapshot.headOID ?? snapshot.head.flatMap { head in
            snapshot.references.first { $0.fullName == "refs/heads/\(head)" }?.oid
        }
    }

    var graphCommit: RepositoryCommit {
        RepositoryCommit(oid: id, parents: headOID.map { [$0] } ?? [],
                         author: "", date: .distantPast, message: "Staging")
    }
}

@MainActor
final class AppModel: ObservableObject {
    let editor = ProjectEditor()
    @Published var selectedTab: ProjectTab = .info
    @Published var configuration = AppConfiguration(root: "", machine: Configuration.defaultMachine)
    @Published var github = GitHubState()
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
    @Published var workingDiffStaged = false
    @Published var commitDiffError: String?
    @Published var isLoadingCommitDiff = false
    @Published var projectSnapshot: RepositorySnapshot?
    @Published var peerSnapshots: [UUID: RepositorySnapshot] = [:]
    @Published var peerStagingErrors: [UUID: String] = [:]
    @Published private(set) var isLoadingPeerStaging = false
    private var peerStagingRequest: UUID?
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
    private var pendingPlacement: String?
    private let sendCommand: (EngineCommand) async throws -> EngineReply

    init(connectToHelper: Bool = true,
         sendCommand: @escaping (EngineCommand) async throws -> EngineReply = EngineClient.send) {
        self.sendCommand = sendCommand
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

    var selectedEditorRepositoryURL: URL? {
        guard let name = selectedProjectName, placement(of: name, on: nil) == .checkedOut else { return nil }
        return selectedLocalRepositoryURL
    }

    var availableTabs: [ProjectTab] {
        selectedStaging?.source == .local ? ProjectTab.allCases : [.info, .diff]
    }

    var stagingRows: [ProjectStaging] {
        guard let snapshot = projectSnapshot, let source = projectSource else { return [] }
        var rows: [ProjectStaging] = []
        if snapshot.workingChanges != nil {
            rows.append(ProjectStaging(id: CommitGraphGenerator.workingChangesID, source: source,
                                       host: source == .local ? configuration.machine : projectSourceLabel(source),
                                       snapshot: snapshot))
        }
        if case .backup = source { return rows }
        for host in configuration.hosts where source != .host(host.id) {
            guard let peer = peerSnapshots[host.id], peer.workingChanges != nil else { continue }
            rows.append(ProjectStaging(id: CommitGraphGenerator.workingChangesID + ":" + host.id.uuidString,
                                       source: .host(host.id), host: host.name, snapshot: peer))
        }
        return rows
    }

    var selectedStaging: ProjectStaging? { stagingRows.first { $0.id == selectedCommitID } }

    func refreshPeerStaging() async {
        guard let name = selectedProjectName, let source = projectSource,
              peerStagingRequest == nil else { return }
        if case .backup = source { return }
        let request = UUID()
        peerStagingRequest = request
        isLoadingPeerStaging = true
        defer {
            if peerStagingRequest == request {
                peerStagingRequest = nil
                isLoadingPeerStaging = false
            }
        }
        let configuration = configuration
        let hosts = configuration.hosts.filter {
            source != .host($0.id) && configuration.folders.first { $0.name == name }?.availableHosts.contains($0.id) == true
        }
        let ids = Set(hosts.map(\.id))
        peerSnapshots = peerSnapshots.filter { ids.contains($0.key) }
        peerStagingErrors = peerStagingErrors.filter { ids.contains($0.key) }
        await withTaskGroup(of: (UUID, Result<RepositorySnapshot, Error>).self) { group in
            for host in hosts {
                group.addTask {
                    (host.id, Result { try Self.content(for: name, source: .host(host.id),
                                                        configuration: configuration).snapshot })
                }
            }
            for await (id, result) in group {
                guard !Task.isCancelled, peerStagingRequest == request,
                      selectedProjectName == name, projectSource == source else { continue }
                switch result {
                case .success(let snapshot):
                    peerSnapshots[id] = snapshot
                    peerStagingErrors[id] = nil
                case .failure(let error):
                    peerSnapshots[id] = nil
                    peerStagingErrors[id] = String(describing: error)
                }
                if selectedCommitID == CommitGraphGenerator.workingChangesID + ":" + id.uuidString {
                    selectCommit(selectedStaging != nil ? selectedCommitID : nil)
                }
            }
        }
    }

    fileprivate var projectSources: [ProjectSource] {
        guard let name = selectedProjectName else { return [] }
        return sources(for: name)
    }

    fileprivate var projectSourceMachine: String? {
        switch projectSource {
        case .local:
            return configuration.machine
        case .host(let id):
            return configuration.hosts.first { $0.id == id }?.name
        case .backup(let id):
            return backupItems.first { $0.name == selectedProjectName }?
                .snapshots.first { $0.id == id }?.machine
        case nil:
            return nil
        }
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
                    let reply = try await sendCommand(.snapshot)
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
                let reply = try await sendCommand(.snapshot)
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
                let reply = try await sendCommand(command)
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
        github = snapshot.github
        globalShortcutEnabled = snapshot.globalShortcutEnabled
        status = snapshot.status
        error = snapshot.error
        isChecking = snapshot.isChecking
        isRunning = snapshot.isRunning
        isPaused = snapshot.isPaused
        backupItems = snapshot.backupItems
        backupError = snapshot.backupError
        restoringBackup = snapshot.restoringBackup
        placementInProgress = pendingPlacement ?? snapshot.placementInProgress
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
                    editor.refresh()
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
        guard editor.confirmDiscard() else { return }
        selectedProjectName = name
        editor.connect(selectedEditorRepositoryURL)
        if let name { UserDefaults.standard.set(name, forKey: selectedProjectKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedProjectKey) }
        selectCommit(nil)
        projectSnapshot = nil
        peerStagingRequest = nil
        isLoadingPeerStaging = false
        peerSnapshots = [:]
        peerStagingErrors = [:]
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
        peerStagingRequest = nil
        isLoadingPeerStaging = false
        peerSnapshots = [:]
        peerStagingErrors = [:]
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
                    if let oid = selectedCommitID {
                        if CommitGraphGenerator.isStaging(oid) {
                            selectCommit(stagingRows.contains { $0.id == oid } ? oid : nil)
                        } else if selectedCommitDiff == nil {
                            selectCommit(oid)
                        }
                    }
                    await refreshPeerStaging()
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
        let staging = stagingRows.first { $0.id == oid }
        if selectedCommitID != oid {
            selectedTab = staging != nil
                ? (staging?.source == .local && selectedEditorRepositoryURL != nil ? .editor : .diff)
                : (oid == nil ? .info : .diff)
        }
        if let staging, selectedCommitID != oid {
            let changes = staging.snapshot.workingChanges
            workingDiffStaged = changes?.unstaged == 0 && changes?.untracked == 0 && changes?.conflicted == 0
        }
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        selectedCommitID = oid
        selectedCommitDiff = nil
        commitDiffError = nil
        isLoadingCommitDiff = false
        guard let oid, let name = selectedProjectName, let source = staging?.source ?? projectSource else { return }
        let historySource = projectSource
        isLoadingCommitDiff = true
        let configuration = configuration
        let staged = workingDiffStaged
        Task {
            do {
                let diff = try await Task.detached(priority: .userInitiated) {
                    try Self.diff(for: name, oid: oid, staged: staged, source: source, configuration: configuration)
                }.value
                guard generation == diffLoadGeneration, selectedProjectName == name,
                      selectedCommitID == oid, projectSource == historySource else { return }
                selectedCommitDiff = diff
                isLoadingCommitDiff = false
            } catch {
                guard generation == diffLoadGeneration, selectedProjectName == name,
                      selectedCommitID == oid, projectSource == historySource else { return }
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
        guard placementInProgress == nil else { return }
        if hostID == nil, placement(of: project, on: nil) == .notPresent {
            setPlacement(.mirrored, project: project, hostID: nil, checkoutAfterMirror: true)
            return
        }
        let preferred: String?
        if let hostID { preferred = remoteProjects[hostID]?[project]?.defaultBranch }
        else { preferred = localProjects[project]?.defaultBranch }
        if let preferred {
            setPlacement(.checkedOut, project: project, hostID: hostID, branch: preferred)
            return
        }
        requestCheckout(project, hostID: hostID, references: projectSnapshot?.references ?? [])
    }

    private func requestCheckout(_ project: String, hostID: UUID?, references: [RepositoryReference]) {
        let branches = checkoutBranches(in: references)
        guard !branches.isEmpty else {
            error = "No branch is available to check out yet."
            return
        }
        checkoutRequest = CheckoutRequest(project: project, hostID: hostID, branches: branches)
    }

    private func checkoutBranches(in references: [RepositoryReference]) -> [String] {
        Set(references.compactMap { reference -> String? in
            if reference.fullName.hasPrefix("refs/heads/") { return reference.name }
            guard reference.fullName.hasPrefix("refs/remotes/") else { return nil }
            let pieces = reference.name.split(separator: "/", maxSplits: 1)
            return pieces.count == 2 && pieces[1] != "HEAD" ? String(pieces[1]) : nil
        }).sorted()
    }

    @discardableResult
    func setPlacement(_ placement: ProjectPlacement, project: String, hostID: UUID?, branch: String? = nil,
                      checkoutAfterMirror: Bool = false) -> Task<Void, Never>? {
        guard placementInProgress == nil else { return nil }
        if hostID == nil, project == selectedProjectName, !editor.confirmDiscard() { return nil }
        let awaitMirror = hostID == nil && placement == .mirrored && self.placement(of: project, on: nil) == .notPresent
        let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
        let expectedBranches = selectedProjectName == project
            ? projectSnapshot.map { $0.references.filter { $0.fullName.hasPrefix("refs/heads/") }.map(\.name) } : nil
        pendingPlacement = hostID?.uuidString ?? "local"
        placementInProgress = pendingPlacement
        error = nil
        updateRepositoryWatcher()
        return Task {
            defer {
                pendingPlacement = nil
                placementInProgress = nil
                updateRepositoryWatcher()
            }
            do {
                var reply = try await sendCommand(.setPlacement(placement, project: project, hostID: hostID, branch: branch))
                let deadline = Date().addingTimeInterval(120)
                while true {
                    apply(reply)
                    if let message = reply.error ?? reply.snapshot?.error {
                        throw SyncError.invalidConfiguration(message)
                    }
                    if reply.snapshot?.placementInProgress == nil { break }
                    guard Date() < deadline else {
                        throw SyncError.invalidConfiguration("The host is still updating. Check its status before trying again.")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    reply = try await sendCommand(.snapshot)
                }
                if awaitMirror {
                    // Creating the mirror only enables sync; wait for incoming refs before offering checkout.
                    let repository = Repository(name: project, url: root.appendingPathComponent(project))
                    while true {
                        let snapshot = try await Task.detached(priority: .userInitiated) {
                            try repository.snapshot(limit: 0)
                        }.value
                        let branches = checkoutBranches(in: snapshot.references)
                        let ready = !branches.isEmpty
                            && Set(expectedBranches ?? []).isSubset(of: Set(branches))
                        if ready {
                            if checkoutAfterMirror {
                                requestCheckout(project, hostID: nil, references: snapshot.references)
                            }
                            break
                        }
                        guard Date() < deadline, !isPaused else {
                            throw SyncError.invalidConfiguration("The mirror is waiting for branch data. Resume sync or check the source host, then try Check Out again.")
                        }
                        try await Task.sleep(for: .milliseconds(250))
                        reply = try await sendCommand(.snapshot)
                        apply(reply)
                        if let message = reply.error ?? reply.snapshot?.error {
                            throw SyncError.invalidConfiguration(message)
                        }
                    }
                }
                if selectedProjectName == project { loadProject(project, from: sources(for: project)) }
            } catch {
                self.error = String(describing: error)
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
        guard panel.runModal() == .OK, let root = panel.url?.path else { return }
        perform(.setBackupDestination(root))
    }

    func unarchiveBackup(_ item: BackupItem, snapshot: BackupSnapshot) {
        perform(.restoreBackup(item, snapshot))
    }

    func refreshLocal() { perform(.refresh) }
    func githubAction(_ action: GitHubAction) { perform(.github(action)) }

    func githubCounts(for project: String) -> GitHubCounts? {
        let identities = localProjects[project]?.githubRepositories
            ?? configuration.hosts.compactMap { remoteProjects[$0.id]?[project]?.githubRepositories }.first ?? []
        return identities.compactMap { github.counts[$0] }.first
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
                let reply = try await sendCommand(.addHost(
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

    private nonisolated static func diff(for name: String, oid: String, staged: Bool, source: ProjectSource,
                                         configuration: AppConfiguration) throws -> String {
        switch source {
        case .local:
            let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
            let repository = Repository(name: name, url: root.appendingPathComponent(name))
            return try CommitGraphGenerator.isStaging(oid)
                ? repository.workingDiff(staged: staged) : repository.diff(at: oid)
        case .host(let id):
            guard let host = configuration.hosts.first(where: { $0.id == id }) else {
                throw SyncError.invalidConfiguration("The selected host is no longer configured.")
            }
            return try Runner.projectDiff(name, oid: CommitGraphGenerator.isStaging(oid) ? nil : oid, staged: staged,
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
    @State private var projectSelection: String?
    @AppStorage("git-tree-column-width") private var gitTreeColumnWidth = 440.0
    @State private var initialGitTreeColumnWidth: Double

    init(model: AppModel, defaults: UserDefaults = .standard) {
        self.model = model
        _gitTreeColumnWidth = AppStorage(wrappedValue: 440, "git-tree-column-width", store: defaults)
        // Startup can lay out at the minimum width before the window frame is restored.
        // Those geometry updates must not change the width we are trying to restore.
        _initialGitTreeColumnWidth = State(initialValue: defaults.object(forKey: "git-tree-column-width") as? Double ?? 440)
    }

    private var projects: [String] {
        model.projectNames.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
    }
    private var archived: [BackupItem] {
        model.archivedProjects.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $projectSelection) {
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: Double.self) { geometry in
                    geometry.size.width
                } action: { width in
                    if width >= 280 { gitTreeColumnWidth = width }
                }
                .background(GitTreeWidthRestorer(width: initialGitTreeColumnWidth))
                .toolbar { projectToolbar }
                .navigationSplitViewColumnWidth(min: 280, ideal: initialGitTreeColumnWidth, max: .infinity)
        } detail: {
            switch model.selectedTab {
            case .info:
                if let name = model.selectedProjectName { ProjectOverview(name: name, model: model) }
                else { ContentUnavailableView("Select a Project", systemImage: "sidebar.left") }
            case .diff:
                ProjectDetailView(model: model)
            case .editor:
                if model.selectedEditorRepositoryURL != nil {
                    HSplitView {
                        ProjectFileBrowser(editor: model.editor)
                            .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                        ProjectEditorView(editor: model.editor)
                            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ContentUnavailableView("No Local Working Copy", systemImage: "folder",
                                           description: Text("Check out this project on this Mac to edit its files."))
                }
            case .terminal:
                ContentUnavailableView {
                    Label("Terminal", systemImage: "terminal")
                } description: {
                    Text("An embedded terminal is coming next. Open the local project in your terminal app.")
                } actions: {
                    Button("Open in Terminal", action: model.openSelectedProjectInTerminal)
                        .disabled(model.selectedLocalRepositoryURL == nil)
                }
            }
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
            projectSelection = model.selectedProjectName
        }
        .onChange(of: model.selectedProjectName) { _, name in projectSelection = name }
        .onChange(of: projectSelection) { _, name in
            guard let name, name != model.selectedProjectName else { return }
            Task { @MainActor in
                model.selectProject(name)
                projectSelection = model.selectedProjectName
            }
        }
        .onChange(of: model.selectedEditorRepositoryURL) { _, url in
            // A checkout can become available without changing the selected project.
            if !model.editor.isDirty { model.editor.connect(url) }
        }
        .sheet(item: $model.checkoutRequest) { request in
            BranchPicker(request: request, model: model)
        }
        .onOpenURL { url in
            if url.scheme == "gitsync", url.host == "github-connected" {
                model.githubAction(.refresh)
                openSettings()
                NSApplication.shared.activate()
            } else if url.scheme == "gitsync", url.host == "settings" {
                openSettings()
                NSApplication.shared.activate()
            } else if model.openProjectURL(url) {
                NSApplication.shared.activate()
            }
        }
    }
    @ToolbarContentBuilder private var projectToolbar: some ToolbarContent {
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
        ToolbarItem(placement: .primaryAction) {
            Picker("Main view", selection: $model.selectedTab) {
                ForEach(model.availableTabs) { tab in
                    Label("Show \(tab.title)", systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Choose the main view")
        }
        ToolbarItemGroup {
            Button("Reveal in Finder", systemImage: "folder", action: model.revealSelectedProjectInFinder)
                .disabled(model.selectedLocalRepositoryURL == nil)
                .help("Reveal in Finder")
            Button("Open in Terminal", systemImage: "terminal", action: model.openSelectedProjectInTerminal)
                .disabled(model.selectedLocalRepositoryURL == nil)
                .help("Open in Terminal")
            Button("Open in External Editor", systemImage: "square.and.pencil", action: model.openSelectedProjectInEditor)
                .disabled(model.selectedLocalRepositoryURL == nil)
                .help("Open in External Editor")
            Button(action: model.openSelectedProjectOnGitHub) {
                Label {
                    Text("Open on GitHub")
                } icon: {
                    Image("GitHub", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
            }
            .disabled(model.projectGitHubURL == nil)
            .help("Open on GitHub")
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refreshProject(); model.editor.refresh() }
                .help("Refresh project")
        }
    }
}

private struct GitTreeWidthRestorer: NSViewRepresentable {
    let width: Double

    func makeNSView(context: Context) -> RestoringView { RestoringView(width: width) }
    func updateNSView(_ view: RestoringView, context: Context) {}

    final class RestoringView: NSView {
        let width: Double
        var restored = false

        init(width: Double) {
            self.width = width
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // SwiftUI's Window scene applies its own split layout after initial geometry.
            DispatchQueue.main.async { [weak self] in self?.restoreWidth() }
        }

        private func restoreWidth() {
            guard !restored, let window else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            guard bounds.width > 0 else { return }
            var pane: NSView = self
            while let parent = pane.superview {
                if let split = parent as? NSSplitView,
                   let index = split.arrangedSubviews.firstIndex(of: pane),
                   index < split.arrangedSubviews.count - 1 {
                    restored = true
                    split.setPosition(pane.frame.maxX + width - bounds.width, ofDividerAt: index)
                    return
                }
                pane = parent
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
            HStack(spacing: 3) {
                Text(name).lineLimit(1)
                if let folder = model.configuration.folders.first(where: { $0.name == name }),
                   !folder.availableLocally {
                    Image(systemName: "globe")
                        .font(.caption2.weight(.light))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 4)
            if let counts = model.githubCounts(for: name),
               counts.stars > 0 || counts.pullRequests > 0 || counts.issues > 0 {
                HStack(spacing: 6) {
                    if counts.stars > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star")
                            Text(counts.stars.formatted(.number.notation(.compactName)))
                        }
                    }
                    if counts.pullRequests > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.pull")
                            Text(counts.pullRequests.formatted(.number.notation(.compactName)))
                        }
                    }
                    if counts.issues > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.circle")
                            Text(counts.issues.formatted(.number.notation(.compactName)))
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary).fixedSize()
                .help(counts.summary)
            }
        }
        .help(projectSummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projectSummary)
    }

    private var projectSummary: String {
        guard let folder = model.configuration.folders.first(where: { $0.name == name }) else { return name }
        let count = (folder.availableLocally ? 1 : 0) + folder.availableHosts.count
        let github = model.githubCounts(for: name).map { " — " + $0.summary } ?? ""
        return "\(name) — on \(count) host\(count == 1 ? "" : "s")\(github)"
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
                CommitList(snapshot: snapshot, staging: model.stagingRows,
                           isLoadingPeers: model.isLoadingPeerStaging,
                           stagingErrors: model.configuration.hosts.compactMap { host in
                               model.peerStagingErrors[host.id].map { (id: host.id, host: host.name, message: $0) }
                           }, hosts: model.configuration.hosts, localMachine: model.configuration.machine,
                           sourceMachine: model.projectSourceMachine, selection: Binding(
                    get: { model.selectedCommitID }, set: model.selectCommit
                ))
            } else {
                ContentUnavailableView("No Available Copy", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Bring this project to a configured host to render its Git tree and README."))
            }
        }
        .navigationTitle(model.selectedProjectName ?? "Git Tree")
        .task(id: model.selectedProjectName) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await model.refreshPeerStaging()
            }
        }

    }
}

private struct CommitList: View {
    let snapshot: RepositorySnapshot
    let hosts: [SyncHost]
    @Binding var selection: String?
    private let graph: CommitGraphModel
    private let sourceMachine: String?
    private let headOID: String?
    private let rows: [RepositoryCommit]
    let staging: [ProjectStaging]
    let stagingErrors: [(id: UUID, host: String, message: String)]
    let isLoadingPeers: Bool

    init(snapshot: RepositorySnapshot, staging: [ProjectStaging], isLoadingPeers: Bool, stagingErrors: [(id: UUID, host: String, message: String)],
         hosts: [SyncHost], localMachine: String, sourceMachine: String?, selection: Binding<String?>) {
        self.snapshot = snapshot
        self.staging = staging
        self.stagingErrors = stagingErrors
        self.isLoadingPeers = isLoadingPeers
        self.hosts = hosts
        self.sourceMachine = sourceMachine
        _selection = selection
        headOID = snapshot.headOID ?? snapshot.head.flatMap { head in
            snapshot.references.first { $0.fullName == "refs/heads/\(head)" }?.oid
        }
        rows = CommitGraphGenerator.insertingStaging(staging.map(\.graphCommit), into: snapshot.commits)
        graph = CommitGraphGenerator.generate(
            commits: rows, headOID: headOID,
            branchNames: Dictionary(grouping: snapshot.references.filter(\.isGraphBranch), by: \.oid)
                .mapValues { RepositoryReference.graphNames($0, hosts: hosts, sourceMachine: sourceMachine) },
            preferredHost: localMachine
        )
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, commit in
                if let checkout = staging.first(where: { $0.id == commit.oid }) {
                    stagingRow(checkout, at: index)
                } else {
                    CommitRow(commit: commit,
                              isCurrent: commit.oid == headOID,
                              references: snapshot.references.filter { $0.oid == commit.oid },
                              hosts: hosts, sourceMachine: sourceMachine, graph: graph, rowIndex: index)
                        .listRowSeparator(.hidden)
                        .tag(commit.oid)
                }
            }
            if isLoadingPeers {
                Label("Refreshing host staging…", systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(stagingErrors, id: \.id) { error in
                Label("\(error.host) staging unavailable. Try Refresh.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(error.message)
                    .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if rows.isEmpty && stagingErrors.isEmpty && !isLoadingPeers {
                ContentUnavailableView("No Commits", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    @ViewBuilder private func stagingRow(_ checkout: ProjectStaging, at index: Int) -> some View {
        if let changes = checkout.snapshot.workingChanges {
            let status = changes.isEmpty ? "Clean" : changes.summary
            HStack(alignment: .top, spacing: 8) {
                BranchGraphRowCanvas(model: graph, rowIndex: index, commitOID: checkout.id)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Staging").fixedSize()
                        Text(checkout.host).font(.caption).foregroundStyle(.secondary)
                        if !changes.isEmpty {
                            Text(changes.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.lineLimit(1)
                    Text(stagingPaths(changes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(([checkout.host, status] + (changes.files ?? []).map { file in
                file.path + (file.additions.map { " +\($0)" } ?? "")
                    + (file.deletions.map { " −\($0)" } ?? "")
            }).joined(separator: "\n"))
            .accessibilityElement(children: .combine)
            .listRowSeparator(.hidden)
            .tag(checkout.id)
        }
    }

    private func stagingPaths(_ changes: RepositoryWorkingChanges) -> AttributedString {
        guard let files = changes.files, !files.isEmpty else {
            return AttributedString(changes.isEmpty ? "Clean" : changes.summary)
        }
        var text = AttributedString()
        for file in files {
            if !text.characters.isEmpty { text += AttributedString(" · ") }
            text += AttributedString(file.path)
            if let count = file.additions, count > 0 {
                var label = AttributedString(" +\(count)")
                label.foregroundColor = .green
                text += label
            }
            if let count = file.deletions, count > 0 {
                var label = AttributedString(" −\(count)")
                label.foregroundColor = .red
                text += label
            }
        }
        return text
    }
}

func compactCommitAge(from date: Date, to now: Date, calendar: Calendar = .current) -> String {
    let units: [(Calendar.Component, String)] = [
        (.year, "y"), (.month, "mn"), (.day, "d"), (.hour, "h"), (.minute, "m")
    ]
    let components = calendar.dateComponents(Set(units.map(\.0)), from: min(date, now), to: max(date, now))
    let parts = units.compactMap { unit, suffix -> String? in
        guard let value = components.value(for: unit), value > 0 else { return nil }
        return "\(value)\(suffix)"
    }
    return parts.isEmpty ? "0m" : parts.prefix(2).joined(separator: " ")
}

private struct CommitRow: View {
    let commit: RepositoryCommit
    let isCurrent: Bool
    let references: [RepositoryReference]
    let hosts: [SyncHost]
    let sourceMachine: String?
    let graph: CommitGraphModel
    let rowIndex: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BranchGraphRowCanvas(model: graph, rowIndex: rowIndex, commitOID: commit.oid)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(commit.subject).lineLimit(1)
                    ForEach(references.filter(\.isGraphTag)) { tag in
                        Label(tag.displayName(hosts: hosts), systemImage: "tag")
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .help(tag.displayName(hosts: hosts))
                    }
                }
                HStack {
                    Text(commit.author)
                    CopyableCommitSHA(sha: commit.oid)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(compactCommitAge(from: commit.date, to: context.date))
                            .monospacedDigit()
                            .help(commit.date.formatted())
                    }
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
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                .padding(-4)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .help(RepositoryReference.graphNames(references, hosts: hosts, sourceMachine: sourceMachine).joined(separator: "\n"))
        .accessibilityValue(([isCurrent ? "Checked out commit" : ""] +
            RepositoryReference.graphNames(references, hosts: hosts, sourceMachine: sourceMachine)).filter { !$0.isEmpty }.joined(separator: ", "))
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
        .help("Copy full commit SHA: \(sha)")
        .accessibilityValue(sha)
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
        if model.selectedProjectName != nil {
            if let staging = model.selectedStaging {
                DiffDetail(title: "Staging", diff: model.selectedCommitDiff,
                           isLoadingDiff: model.isLoadingCommitDiff, error: model.commitDiffError) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Staging").font(.headline)
                        Text(staging.snapshot.workingChanges?.summary ?? "")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("From \(staging.host)").font(.callout).foregroundStyle(.secondary)
                        Picker("Changes", selection: Binding(get: { model.workingDiffStaged }, set: {
                            model.workingDiffStaged = $0
                            model.selectCommit(staging.id)
                        })) {
                            Text("Unstaged").tag(false)
                            Text("Staged").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    .padding().frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let commitID = model.selectedCommitID,
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
                ContentUnavailableView("Select a Commit", systemImage: "plus.forwardslash.minus",
                                       description: Text("Choose a commit or Staging to view its diff."))
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
                         placement: model.placement(of: project, on: nil), canArchive: canArchive, isLocal: true,
                         progress: model.placementInProgress == "local") {
                if $0 == .checkedOut { model.checkOut(project, hostID: nil) }
                else { model.setPlacement($0, project: project, hostID: nil) }
            }
            ForEach(model.configuration.hosts) { host in
                PlacementRow(project: project, name: host.name,
                             placement: model.placement(of: project, on: host.id), canArchive: canArchive,
                             progress: model.placementInProgress == host.id.uuidString) {
                    if $0 == .checkedOut { model.checkOut(project, hostID: host.id) }
                    else { model.setPlacement($0, project: project, hostID: host.id) }
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
    var isLocal = false
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
                        Button("Mirror on this Host (Bare Checkout)") { change(.mirrored) }
                        if isLocal { Button("Check Out") { change(.checkedOut) } }
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
    var body: some View {
        DiffDetail(title: commit.subject, diff: diff, isLoadingDiff: isLoadingDiff, error: error) { header }
    }

    private var header: some View {
        VStack(alignment: .leading) {
            Text(commit.message).font(.headline).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { byline }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading) { byline }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) { identifiers }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading) { identifiers }
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var byline: some View {
        Group {
            Text(commit.author).textSelection(.enabled)
            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                .help(commit.date.formatted(date: .long, time: .standard))
            if let source { Text("From \(source)") }
        }
    }

    private var identifiers: some View {
        Group {
            HStack {
                Text("Commit").foregroundStyle(.secondary)
                CopyableCommitSHA(sha: commit.oid)
            }
            if !commit.parents.isEmpty {
                HStack(alignment: .top) {
                    Text(commit.parents.count == 1 ? "Parent" : "Parents").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        ForEach(commit.parents, id: \.self) { CopyableCommitSHA(sha: $0) }
                    }
                }
            }
            if !references.isEmpty {
                Label(references.map { $0.displayName(hosts: hosts) }.joined(separator: ", "),
                      systemImage: "point.3.connected.trianglepath.dotted")
                    .textSelection(.enabled)
                    .accessibilityLabel("References")
                    .accessibilityValue(references.map { $0.displayName(hosts: hosts) }.joined(separator: ", "))
            }
        }
    }
}

private struct DiffDetail<Header: View>: View {
    let title: String
    let diff: String?
    let isLoadingDiff: Bool
    let error: String?
    @ViewBuilder var header: Header
    @Environment(\.colorScheme) private var colorScheme
    @State private var files: [DiffFile] = []
    @State private var visibleFiles: Set<UUID> = []
    @State private var isParsingDiff = false

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        if isLoadingDiff || isParsingDiff {
                            ProgressView("Reading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .navigationTitle(title)
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

            Form {
                Section("GitHub") {
                    LabeledContent("Connection", value: model.github.status)
                    HStack {
                        if model.github.connected {
                            Button("Refresh") { model.githubAction(.refresh) }
                            Button("Repository Access…") { model.githubAction(.installations) }
                                .disabled(model.github.installationURL == nil)
                            Button("Disconnect") { model.githubAction(.disconnect) }
                        } else {
                            Button("Connect GitHub…") { model.githubAction(.connect) }
                        }
                    }
                    if let error = model.github.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section("Notifications") {
                    LabeledContent("Push updates", value: model.github.pushStatus)
                    LabeledContent("Banners", value: model.github.notificationPermission)
                    Button("Allow Notifications…") { model.githubAction(.requestNotificationPermission) }
                    Text("Notifications cover tracked GitHub projects. Stars and open PR/issue counts appear in the sidebar.")
                        .foregroundStyle(.secondary)
                    Text("Updates arrive through push notifications, with catch-up on launch, reconnect, and Refresh.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("GitHub", systemImage: "network") }

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
