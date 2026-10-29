#if os(macOS)
import AppKit
import LocalAuthentication
import ServiceManagement
import SwiftUI
import Textual
import UniformTypeIdentifiers
import PortalCore
import PortalEngine
import PortalGraph
import PortalTerminal
import gitdiff

@main
struct PortalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel

    init() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "migrated-portal-preferences") && !defaults.bool(forKey: "migrated-gitinuum-preferences") {
            if let previous = defaults.persistentDomain(forName: "dev.mxcl.git-sync") {
                for (key, value) in previous { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "migrated-portal-preferences")
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        Window("Portal", id: "projects") {
            ProjectBrowserView(model: model)
                .focusedSceneValue(\.paletteModel, model)
                .background(GlobalShortcutReceiver(model: model))
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            SidebarCommands()
            ProjectCommands()
            ProjectViewCommands()
            ProjectTerminalCommands(workspace: model.terminals)
            CommandGroup(after: .appSettings) {
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "New Terminal Window", action: #selector(newTerminalWindow), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func newTerminalWindow() { TerminalApplication.open() }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        TerminalApplication.open(files)
    }
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

enum ProjectSource: Codable, Hashable, Identifiable, Sendable {
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

    var checkouts: [ProjectStaging] = []

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

struct ProjectWindowCache: Codable, Sendable {
    let engine: EngineSnapshot
    let name: String
    let source: ProjectSource
    let showAuxiliaryHistory: Bool
    let content: RepositoryContent
}

@MainActor
final class AppModel: ObservableObject {
    let terminals = TerminalWorkspace()
    @Published var selectedTab: ProjectTab = .info
    @Published var terminalSource: ProjectSource?
    @Published var configuration = AppConfiguration(root: "", machine: Configuration.defaultMachine)
    @Published var github = GitHubState()
    @Published var globalShortcutEnabled = true
    @Published var mergedBranchCleanupEnabled = false
    @Published var status = "Starting Sync Helper"
    @Published var error: String?
    @Published var hostError: String?
    @Published var isChecking = false
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var backupItems: [BackupItem] = []
    @Published var backupTransferring: [String: Bool] = [:]
    @Published var backupError: String?
    @Published var deletingBackup: String?
    @Published var restoringBackup: String?
    @Published var selectedHostID: UUID?
    @Published var showingAddHost = false
    @Published var showingRenameHost = false
    @Published var showingOverlapConfirmation = false
    @Published var overlappingRepositories: [String] = []
    @Published private(set) var showingPalette = false
    @Published private(set) var paletteCommit: RepositoryCommit?
    private weak var palettePreviousResponder: NSResponder?
    private weak var paletteWindow: NSWindow?
    private var paletteView: NSView?
    private var paletteNavigation = UUID()
    private var paletteCommandTask: Task<Void, Never>?
    private struct NavigationLocation {
        let project: String
        let commit: String?
        let tab: ProjectTab
        let terminal: ProjectSource?
    }
    @Published private var backHistory: [NavigationLocation] = []
    @Published private var forwardHistory: [NavigationLocation] = []
    private var restoringNavigation = false
    private var pendingNavigation: NavigationLocation?

    var canGoBack: Bool { !backHistory.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    private var navigationLocation: NavigationLocation? {
        selectedProjectName.map {
            NavigationLocation(project: $0, commit: selectedCommitID,
                               tab: selectedTab, terminal: terminalSource)
        }
    }

    private func recordNavigation() {
        guard !restoringNavigation else { return }
        pendingNavigation = nil
        if let location = navigationLocation { backHistory.append(location) }
        forwardHistory.removeAll()
    }

    func goBack() { navigateHistory(backward: true) }
    func goForward() { navigateHistory(backward: false) }

    private func navigateHistory(backward: Bool) {
        guard let destination = backward ? backHistory.last : forwardHistory.last else { return }
        if let current = navigationLocation {
            if backward { forwardHistory.append(current) } else { backHistory.append(current) }
        }
        if backward { backHistory.removeLast() } else { forwardHistory.removeLast() }
        restoringNavigation = true
        defer { restoringNavigation = false }
        pendingNavigation = nil
        selectProject(destination.project)
        restoreNavigation(destination)
        // Staging destinations need the new repository snapshot before resolving their host.
        if isLoadingProject { pendingNavigation = destination }
    }

    private func restoreNavigation(_ location: NavigationLocation) {
        terminalSource = location.terminal
        selectCommit(location.commit, recordingHistory: false)
        selectedTab = location.tab
    }

    @Published var selectedProjectName: String?
    @Published var selectedCommitID: String?
    @Published var selectedCommitDiff: String?
    @Published var workingDiffStaged = false
    @Published var commitDiffError: String?
    @Published var isLoadingCommitDiff = false
    // Keep the original preference key so existing choices survive the menu rename.
    @Published var showAuxiliaryHistory = UserDefaults.standard.bool(forKey: "show-detached-worktrees") {
        didSet {
            UserDefaults.standard.set(showAuxiliaryHistory, forKey: "show-detached-worktrees")
            selectCommit(nil)
            refreshProject()
        }
    }
    @Published var projectSnapshot: RepositorySnapshot?
    @Published var peerSnapshots: [UUID: RepositorySnapshot] = [:]
    @Published var peerStagingErrors: [UUID: String] = [:]
    @Published private(set) var isLoadingPeerStaging = false
    @Published var projectReadme: RepositoryReadme?
    @Published var projectGitHubURL: URL?
    @Published var projectError: String?
    @Published var isLoadingProject = false
    @Published fileprivate var projectSource: ProjectSource? {
        didSet { updateRepositoryWatcher() }
    }
    @Published var placementInProgress: String?
    @Published var renameRequest: ProjectRename.Record?
    @Published var renameProgress: ProjectRename.Progress?
    @Published var cancellingRename = false
    @Published var localProjects: [String: PeerProject] = [:]
    @Published var remoteProjects: [UUID: [String: PeerProject]] = [:]
    @Published var checkoutRequest: CheckoutRequest?
    @Published var helperAvailable = false
    @Published var helperError: String?

    fileprivate var hostDraft = HostDraft()
    fileprivate var hostNameDraft = ""

    private let windowCacheURL: URL?
    private var lastEngineSnapshot: EngineSnapshot?
    private var windowCacheSave: Task<Void, Never>?

    private let selectedProjectKey = "selected-project-v2"
    private let loginMigrationKey = "migrated-portal-menu-helper-login-item-v1"
    private let loginItem = SMAppService.loginItem(identifier: "dev.mxcl.portal.menu-helper")
    let remoteAccess = RemoteAccessModel()
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
    private var observedProjects: [UUID: [String: ObservedProject]] = [:]
    private var projectObservationErrors: [String: String] = [:]
    private var pendingPlacement: String?
    private let sendCommand: (EngineCommand) async throws -> EngineReply

    init(connectToHelper: Bool = true,
         windowCacheURL: URL? = nil,
         sendCommand: @escaping (EngineCommand) async throws -> EngineReply = EngineClient.send) {
        self.sendCommand = sendCommand
        self.windowCacheURL = windowCacheURL ?? (connectToHelper
            ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("dev.mxcl.portal/project-window-v1.json") : nil)
        if let url = self.windowCacheURL,
           let data = try? Data(contentsOf: url),
           let cache = try? JSONDecoder().decode(ProjectWindowCache.self, from: data),
           cache.showAuxiliaryHistory == showAuxiliaryHistory {
            configuration = cache.engine.configuration
            github = cache.engine.github
            backupItems = cache.engine.backupItems
            localProjects = cache.engine.localProjects
            remoteProjects = cache.engine.remoteProjects
            observedProjects = cache.engine.observedProjects
            lastEngineSnapshot = cache.engine
            selectedProjectName = cache.name
            projectSnapshot = cache.content.snapshot
            projectReadme = cache.content.readme
            projectGitHubURL = cache.content.githubURL
            projectSource = cache.source
            refreshProject()
        }
        guard connectToHelper else { return }
        Task { await remoteAccess.launch() }
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

    func backupSidebarStatus(for project: String) -> String {
        guard configuration.backup != nil || configuration.backupDestination != nil else { return "Backup not configured" }
        if backupError != nil || helperError != nil || error != nil { return "Backup unavailable" }
        if isPaused { return "Backup paused" }
        guard isRunning else { return "Backup stopped" }
        guard let transferring = backupTransferring[project] else {
            return "Checking backup…"
        }
        return transferring ? "Transferring backup objects…" : "Backup up to date"
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

    func placementStatus(for project: String, on hostID: UUID?, placement: ProjectPlacement) -> String {
        let isBackupDestination = configuration.backupDestination != nil
            ? hostID == nil : hostID != nil && hostID == configuration.backup?.hostID
        let backedUp = isBackupDestination && backupError == nil && helperError == nil
            && backupItems.contains { $0.name == project && !$0.snapshots.isEmpty }
        if placement == .notPresent { return backedUp ? "Backed up" : "" }
        return placement.title + (backedUp ? " & backed up" : "")
    }

    var selectedLocalRepositoryURL: URL? {
        guard let name = selectedProjectName else { return nil }
        return repositoryURL(for: name)
    }

    var terminalHosts: [TerminalHost] {
        configuration.hosts.map { host in
            TerminalHost(id: host.id.uuidString, name: host.name, peer: host.peer,
                         helperPath: host.executable.hasPrefix("/Applications/")
                            ? URL(fileURLWithPath: host.executable).deletingLastPathComponent()
                                .deletingLastPathComponent().appendingPathComponent(host.executable.hasSuffix("/portald") ? "Helpers/portal-session-bridge" : "Helpers/gitinuum-session-bridge").path
                            : (host.executable.hasSuffix("/portald") ? "~/.local/lib/portal/terminal/portal-session-bridge" : "~/.local/lib/gitinuum/terminal/gitinuum-session-bridge"),
                         directory: host.root)
        }
    }

    var showsCommitDiff: Bool { selectedCommitID != nil && selectedStaging == nil }

    var selectedProjectHostSource: ProjectSource {
        if let source = terminalSource,
           source == .local || configuration.hosts.contains(where: { .host($0.id) == source }) {
            return source
        }
        return projectTerminalSources.first ?? .local
    }

    var showsProjectHostTabs: Bool {
        guard helperAvailable, !isLoadingProject, let name = selectedProjectName else { return false }
        return localProjects[name].map { $0.placement != .unknown } == true
            || remoteProjects.values.contains { $0[name].map { $0.placement != .unknown } == true }
            || isSelectedProjectArchived
    }

    var projectCheckoutSources: [ProjectSource] {
        guard selectedProjectName != nil else { return [] }
        let checkedOut = projectTerminalSources
        return ([ProjectSource.local] + configuration.hosts.map { .host($0.id) })
            .filter { !checkedOut.contains($0) }
    }

    var projectTerminalSources: [ProjectSource] {
        guard let name = selectedProjectName else { return [] }
        return ([ProjectSource.local] + configuration.hosts.map { .host($0.id) }).filter {
            switch $0 {
            case .local: placement(of: name, on: nil) == .checkedOut
            case .host(let id): placement(of: name, on: id) == .checkedOut
            case .backup: false
            }
        }
    }

    func showNextProjectTerminal() {
        let sources = projectTerminalSources
        guard let first = sources.first else { return }
        let current = terminalSource ?? selectedStaging?.source ?? projectSource
        if selectedTab == .terminal, let current, let index = sources.firstIndex(of: current) {
            terminalSource = sources[(index + 1) % sources.count]
        } else {
            terminalSource = current.flatMap { sources.contains($0) ? $0 : nil } ?? first
        }
        if let terminalSource { selectProjectHost(terminalSource) }
        selectedTab = .terminal
    }

    var selectedTerminalHost: TerminalHost? {
        guard case .host(let id) = terminalSource ?? selectedStaging?.source ?? projectSource else { return nil }
        return terminalHosts.first { $0.id == id.uuidString }
    }

    var selectedTerminalDirectory: URL? {
        if let host = selectedTerminalHost, let name = selectedProjectName {
            return URL(fileURLWithPath: host.directory).appendingPathComponent(name)
        }
        return selectedLocalRepositoryURL
    }

    var availableTabs: [ProjectTab] {
        !projectTerminalSources.isEmpty ? [.info, .diff, .terminal] : [.info, .diff]
    }

    var stagingCheckouts: [ProjectStaging] {
        guard let snapshot = projectSnapshot, let source = projectSource else { return [] }
        var rows: [ProjectStaging] = []
        if snapshot.workingChanges != nil, showAuxiliaryHistory || snapshot.head != nil || snapshot.headOID == nil {
            rows.append(ProjectStaging(id: CommitGraphGenerator.workingChangesID, source: source,
                                       host: source == .local ? configuration.machine : projectSourceLabel(source),
                                       snapshot: snapshot))
        }
        if case .backup = source { return rows }
        for host in configuration.hosts where source != .host(host.id) {
            guard let peer = peerSnapshots[host.id], peer.workingChanges != nil,
                  showAuxiliaryHistory || peer.head != nil || peer.headOID == nil else { continue }
            rows.append(ProjectStaging(id: CommitGraphGenerator.workingChangesID + ":" + host.id.uuidString,
                                       source: .host(host.id), host: host.name, snapshot: peer))
        }
        return rows
    }

    var stagingRows: [ProjectStaging] {
        var rows: [ProjectStaging] = []
        for checkout in stagingCheckouts {
            if let sha = checkout.headOID, let index = rows.firstIndex(where: { $0.headOID == sha }) {
                rows[index].checkouts.append(checkout)
            } else {
                var row = checkout
                row.checkouts = [checkout]
                rows.append(row)
            }
        }
        return rows
    }

    var selectedStaging: ProjectStaging? { stagingCheckouts.first { $0.id == selectedCommitID } }

    var selectedStagingRowID: String? {
        stagingRows.first { $0.checkouts.contains { $0.id == selectedCommitID } }?.id ?? selectedCommitID
    }

    func selectProjectHost(_ source: ProjectSource) {
        terminalSource = source
        if selectedStaging != nil, let checkout = stagingCheckouts.first(where: { $0.source == source }) {
            selectCommit(checkout.id)
        }
        selectedTab = .terminal
    }

    var isSelectedProjectArchived: Bool {
        archivedProjects.contains { $0.name == selectedProjectName }
    }

    var toolbarTabs: [ProjectTab] {
        if selectedStaging != nil { return [.diff, .terminal] }
        return isSelectedProjectArchived ? [.info, .diff] : [.diff]
    }

    func selectNextStaging() {
        let rows = stagingRows
        guard !rows.isEmpty else { return }
        let next = selectedCommitID.flatMap { id in rows.firstIndex { $0.checkouts.contains { $0.id == id } } }
            .map { ($0 + 1) % rows.count } ?? 0
        selectCommit(rows[next].id)
    }

    var selectedCommit: RepositoryCommit? {
        guard let selectedCommitID else { return nil }
        return projectSnapshot?.commits.first { $0.oid == selectedCommitID }
            ?? paletteCommit.flatMap { $0.oid == selectedCommitID ? $0 : nil }
    }

    func refreshPeerStaging() async {
        guard let name = selectedProjectName, let source = projectSource else { return }
        if case .backup = source { return }
        let hosts = configuration.hosts.filter {
            source != .host($0.id) && configuration.folders.first { $0.name == name }?.availableHosts.contains($0.id) == true
        }
        let snapshots = Dictionary(uniqueKeysWithValues: hosts.compactMap { host in
            observedProjects[host.id]?[name].map { (host.id, $0.snapshot) }
        })
        if peerSnapshots != snapshots { peerSnapshots = snapshots }
        var errors: [UUID: String] = [:]
        for host in hosts {
            errors[host.id] = projectObservationErrors[host.id.uuidString]
            do { try Self.remoteConfiguration(host, in: configuration).validate() }
            catch { errors[host.id] = String(describing: error) }
        }
        if peerStagingErrors != errors { peerStagingErrors = errors }
        let loading = hosts.contains { observedProjects[$0.id] == nil && errors[$0.id] == nil }
        if isLoadingPeerStaging != loading { isLoadingPeerStaging = loading }
        if let id = selectedCommitID, id.hasPrefix(CommitGraphGenerator.workingChangesID + ":") {
            selectCommit(selectedStaging != nil ? id : nil, recordingHistory: false)
        }
    }

    fileprivate var projectSources: [ProjectSource] {
        guard let name = selectedProjectName else { return [] }
        var sources = sources(for: name)
        if let projectSource, !sources.contains(projectSource) { sources.append(projectSource) }
        return sources
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

    func projectSourceLabel(_ source: ProjectSource) -> String {
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
            helperError = "The embedded Sync Helper is missing. Reinstall Portal."
            return
        }
        connecting = true
        Task {
            defer { connecting = false }
            for attempt in 0..<20 {
                do {
                    let reply = try await sendCommand(.snapshot)
                    apply(reply)
                    if !helperAvailable { helperAvailable = true }
                    if helperError != nil { helperError = nil }
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
                if !helperAvailable { helperAvailable = true }
                if helperError != nil { helperError = nil }
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
                if !helperAvailable { helperAvailable = true }
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
        lastEngineSnapshot = snapshot
        let oldLocal = selectedProjectName.flatMap { name in
            configuration.folders.first(where: { $0.name == name })?.availableLocally
        }
        let oldSource = projectSource
        let sourceConfigurationChanged = configuration.root != snapshot.configuration.root
            || configuration.hosts != snapshot.configuration.hosts
            || configuration.backup != snapshot.configuration.backup
            || configuration.backupDestination != snapshot.configuration.backupDestination
        let changedPeers = Set(snapshot.configuration.hosts.map(\.id).filter { id in
            guard let name = selectedProjectName else { return false }
            return observedProjects[id]?[name]?.revision != snapshot.observedProjects[id]?[name]?.revision
                || projectObservationErrors[id.uuidString] != snapshot.projectObservationErrors[id.uuidString]
        })
        observedProjects = snapshot.observedProjects
        projectObservationErrors = snapshot.projectObservationErrors
        if configuration != snapshot.configuration { configuration = snapshot.configuration }
        if github != snapshot.github { github = snapshot.github }
        if globalShortcutEnabled != snapshot.globalShortcutEnabled { globalShortcutEnabled = snapshot.globalShortcutEnabled }
        if mergedBranchCleanupEnabled != snapshot.mergedBranchCleanupEnabled { mergedBranchCleanupEnabled = snapshot.mergedBranchCleanupEnabled }
        if status != snapshot.status { status = snapshot.status }
        if error != snapshot.error { error = snapshot.error }
        if isChecking != snapshot.isChecking { isChecking = snapshot.isChecking }
        if isRunning != snapshot.isRunning { isRunning = snapshot.isRunning }
        if isPaused != snapshot.isPaused { isPaused = snapshot.isPaused }
        if backupItems != snapshot.backupItems { backupItems = snapshot.backupItems }
        if backupTransferring != (snapshot.backupTransferring ?? [:]) { backupTransferring = snapshot.backupTransferring ?? [:] }
        if backupError != snapshot.backupError { backupError = snapshot.backupError }
        if restoringBackup != snapshot.restoringBackup { restoringBackup = snapshot.restoringBackup }
        if placementInProgress != (pendingPlacement ?? snapshot.placementInProgress) { placementInProgress = pendingPlacement ?? snapshot.placementInProgress }
        if renameRequest != nil, renameProgress != snapshot.renameProgress { renameProgress = snapshot.renameProgress }
        if localProjects != snapshot.localProjects { localProjects = snapshot.localProjects }
        if remoteProjects != snapshot.remoteProjects { remoteProjects = snapshot.remoteProjects }

        let availableNames = Set(configuration.folders.map(\.name)).union(backupItems.map(\.name))
        if selectedProjectName == nil || !availableNames.contains(selectedProjectName!) {
            let saved = UserDefaults.standard.string(forKey: selectedProjectKey)
            let selection = saved.flatMap { availableNames.contains($0) ? $0 : nil }
                ?? projectNames.first ?? archivedProjects.first?.name
            selectProject(selection)
        } else if let name = selectedProjectName {
            let newLocal = configuration.folders.first(where: { $0.name == name })?.availableLocally
            if sourceConfigurationChanged || oldLocal != newLocal || oldSource.map({ !sources(for: name).contains($0) }) == true
                || oldSource == nil && !sources(for: name).isEmpty {
                if sourceConfigurationChanged {
                    projectSnapshot = nil
                    projectReadme = nil
                    projectGitHubURL = nil
                }
                loadProject(name, from: sources(for: name))
            }
        }
        if !changedPeers.isEmpty, let source = projectSource {
            if case .host(let id) = source, changedPeers.contains(id) {
                if isLoadingProject { projectRefreshPending = true }
                else { refreshProject() }
            } else if selectedProjectName != nil {
                Task { await refreshPeerStaging() }
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
        guard ["portal", "gitsync"].contains(url.scheme ?? ""), url.host == "project",
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "name" })?.value,
              !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        selectProject(name)
        return true
    }

    func selectProject(_ name: String?) {
        guard name != selectedProjectName else { return }
        recordNavigation()
        paletteNavigation = UUID()
        terminalSource = nil
        selectedProjectName = name
        if let name { UserDefaults.standard.set(name, forKey: selectedProjectKey) }
        else { UserDefaults.standard.removeObject(forKey: selectedProjectKey) }
        selectCommit(nil, recordingHistory: false)
        projectSnapshot = nil
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
        loadProject(name, from: sources(for: name), selectStaging: !restoringNavigation)
    }

    func refreshProject() {
        guard let name = selectedProjectName else { return }
        loadProject(name, from: projectSource.map { [$0] } ?? sources(for: name))
    }

    fileprivate func selectProjectSource(_ source: ProjectSource) {
        guard source != projectSource, let name = selectedProjectName else { return }
        paletteNavigation = UUID()
        terminalSource = nil
        selectCommit(nil, recordingHistory: false)
        projectSnapshot = nil
        isLoadingPeerStaging = false
        peerSnapshots = [:]
        peerStagingErrors = [:]
        projectReadme = nil
        projectGitHubURL = nil
        projectError = nil
        projectSource = source
        loadProject(name, from: [source])
    }

    private func loadProject(_ name: String, from sources: [ProjectSource], selectStaging: Bool = false) {
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
        let showAuxiliaryHistory = showAuxiliaryHistory
        let configuration = configuration
        Task {
            defer {
                if generation == projectLoadGeneration, projectRefreshPending {
                    projectRefreshPending = false
                    refreshProject()
                }
            }
            await refreshPeerStaging()
            var lastError: Error?
            for source in sources {
                do {
                    let content = try await Task.detached(priority: .userInitiated) {
                        try Self.content(for: name, source: source, configuration: configuration,
                                         showAuxiliaryHistory: showAuxiliaryHistory)
                    }.value
                    guard generation == projectLoadGeneration, selectedProjectName == name else { return }
                    projectSource = source
                    projectError = nil
                    if projectSnapshot != content.snapshot { projectSnapshot = content.snapshot }
                    if projectReadme != content.readme { projectReadme = content.readme }
                    if projectGitHubURL != content.githubURL { projectGitHubURL = content.githubURL }
                    isLoadingProject = false
                    saveProjectWindow(name: name, source: source, content: content,
                                      showAuxiliaryHistory: showAuxiliaryHistory)
                    if let location = pendingNavigation {
                        pendingNavigation = nil
                        restoreNavigation(location)
                    } else if selectStaging, terminalSource == nil, selectedCommitID == nil, let staging = stagingRows.first {
                        selectCommit(staging.id, recordingHistory: false)
                        terminalSource = staging.source
                        selectedTab = .terminal
                    } else if let oid = selectedCommitID {
                        if CommitGraphGenerator.isStaging(oid) {
                            selectCommit(stagingCheckouts.contains { $0.id == oid } ? oid : nil, recordingHistory: false)
                        } else if selectedCommitDiff == nil {
                            selectCommit(oid, recordingHistory: false)
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

    private func saveProjectWindow(name: String, source: ProjectSource, content: RepositoryContent,
                                   showAuxiliaryHistory: Bool) {
        guard let url = windowCacheURL, let engine = lastEngineSnapshot,
              engine.configuration == configuration else { return }
        let cache = ProjectWindowCache(engine: engine, name: name, source: source,
                                       showAuxiliaryHistory: showAuxiliaryHistory, content: content)
        let previous = windowCacheSave
        windowCacheSave = Task {
            await previous?.value
            await Task.detached(priority: .utility) {
                // Disposable presentation data: a failed write falls back to normal loading.
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(cache).write(to: url, options: .atomic)
                } catch { }
            }.value
        }
    }

    func selectCommit(_ oid: String?) {
        selectCommit(oid, recordingHistory: true)
    }

    private func selectCommit(_ oid: String?, recordingHistory: Bool) {
        let row = stagingRows.first { $0.id == oid }
        let oid = row?.checkouts.first { $0.source == terminalSource }?.id ?? oid
        if selectedCommitID != oid {
            if recordingHistory { recordNavigation() }
            paletteNavigation = UUID()
        }
        let staging = stagingCheckouts.first { $0.id == oid }
        if selectedCommitID != oid {
            paletteCommit = nil
            selectedTab = staging != nil
                ? .diff
                : (oid == nil ? .info : .diff)
        }
        if let staging, selectedCommitID != oid {
            terminalSource = staging.source
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

    func archiveHosts(for project: String) -> [UUID?] {
        ([nil] + configuration.hosts.map { Optional($0.id) }).filter {
            let placement = placement(of: project, on: $0)
            return placement == .checkedOut || placement == .mirrored
        }
    }

    var canArchiveSelectedProject: Bool {
        guard let project = selectedProjectName, placementInProgress == nil,
              configuration.backup != nil || configuration.backupDestination != nil else { return false }
        return !archiveHosts(for: project).isEmpty
    }

    func renameSelectedProject() {
        guard let project = selectedProjectName, placementInProgress == nil else { return }
        let field = NSTextField(string: project)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel("New project name")
        let alert = NSAlert()
        alert.messageText = "Rename \(project)?"
        alert.informativeText = "All configured hosts must be online. The backup is renamed first, then the project folders. If any step fails, syncing stays suspended for manual recovery. Close editors and commands using this project first."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let record = ProjectRename.Record(old: project, new: field.stringValue)
        _ = renameProject(record)
    }

    func renameProject(_ record: ProjectRename.Record) -> Task<Void, Never>? {
        guard placementInProgress == nil else { return nil }
        do { try ProjectRename.validate(record) }
        catch { self.error = error.localizedDescription; return nil }
        renameRequest = record
        renameProgress = nil
        cancellingRename = false
        pendingPlacement = "rename"
        placementInProgress = pendingPlacement
        error = nil
        updateRepositoryWatcher()
        return Task {
            defer {
                renameRequest = nil
                renameProgress = nil
                cancellingRename = false
                pendingPlacement = nil
                placementInProgress = nil
                updateRepositoryWatcher()
            }
            do {
                let reply = try await sendCommand(.renameProject(record))
                apply(reply)
                if let message = reply.error {
                    throw SyncError.invalidConfiguration(message)
                }
                if reply.cancelled != true { selectProject(record.new) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancelRename() {
        guard let record = renameRequest, renameProgress == .checking, !cancellingRename else { return }
        cancellingRename = true
        Task {
            do {
                let reply = try await sendCommand(.cancelProjectRename(record.id))
                guard renameRequest?.id == record.id else { return }
                apply(reply)
                if let message = reply.error { error = message }
            } catch { self.error = error.localizedDescription }
            if renameRequest?.id == record.id { cancellingRename = false }
        }
    }

    func archiveSelectedProject() {
        guard canArchiveSelectedProject, let project = selectedProjectName else { return }
        let hosts = archiveHosts(for: project)
        let choices = hosts.map { hostID in
            let name = hostID.flatMap { id in configuration.hosts.first { $0.id == id }?.name }
                ?? "\(configuration.machine) (This Mac)"
            let button = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            button.state = (hostID.map(ProjectSource.host) ?? .local) == selectedProjectHostSource ? .on : .off
            return button
        }
        let list = NSStackView(views: choices)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.setFrameSize(list.fittingSize)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive \(project)?"
        alert.informativeText = "Select the hosts to archive from. Their checkouts and mirrors will be moved to Trash. The backup will remain available to restore."
        alert.accessoryView = list
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Archive")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let selected = zip(hosts, choices).filter { $0.1.state == .on }.map { $0.0 }
        Task { await archive(project, on: selected) }
    }

    func archive(_ project: String, on hosts: [UUID?]) async {
        for hostID in hosts {
            guard archiveHosts(for: project).contains(hostID),
                  let task = setPlacement(.notPresent, project: project, hostID: hostID) else { return }
            await task.value
            guard error == nil else { return }
        }
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

    func deleteBackup(_ item: BackupItem) {
        guard item.status == .archived, deletingBackup == nil else { return }
        deletingBackup = item.name
        Task {
            defer { deletingBackup = nil }
            do {
                let context = LAContext()
                context.localizedFallbackTitle = ""
                var unavailable: NSError?
                if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &unavailable) {
                    guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                        localizedReason: "Permanently delete all backups of \(item.name).") else { return }
                } else {
                    if let unavailable, context.biometryType != .none,
                       unavailable.code != LAError.biometryNotAvailable.rawValue,
                       unavailable.code != LAError.biometryNotEnrolled.rawValue {
                        throw unavailable
                    }
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Delete backup of \(item.name)?"
                    alert.informativeText = "This permanently deletes the stored repository and all its backup snapshots. This cannot be undone."
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Delete Backup")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                }
                let reply = try await sendCommand(.deleteBackup(item.name))
                if let snapshot = reply.snapshot { apply(snapshot) }
                error = reply.error
            } catch let failure as LAError where failure.code == .userCancel || failure.code == .appCancel || failure.code == .systemCancel {
                // Cancellation leaves the backup untouched.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func unarchiveBackup(_ item: BackupItem, snapshot: BackupSnapshot) {
        guard deletingBackup == nil, restoringBackup == nil, placementInProgress == nil else { return }
        let hostID: UUID?
        if case .host(let id) = selectedProjectHostSource { hostID = id } else { hostID = nil }
        perform(.restoreBackup(item, snapshot, hostID: hostID))
    }

    func refreshLocal() { perform(.refresh) }
    func githubAction(_ action: GitHubAction) { perform(.github(action)) }

    private func sidebarProject(_ name: String, hostID: UUID? = nil) -> PeerProject? {
        let inventory = hostID.map { remoteProjects[$0]?[name] } ?? localProjects[name]
        guard let inventory, selectedProjectName == name else { return inventory }
        let source: ProjectSource = hostID.map(ProjectSource.host) ?? .local
        let snapshot = projectSource == source ? projectSnapshot : hostID.flatMap { peerSnapshots[$0] }
        guard let snapshot, inventory.placement == .checkedOut else { return inventory }
        let tips = RepositoryBranchTips(local: Dictionary(uniqueKeysWithValues: snapshot.references
            .filter { $0.fullName.hasPrefix("refs/heads/") }.map { ($0.name, $0.oid) }),
            github: snapshot.branchTips?.github ?? inventory.branchTips?.github ?? [:])
        return PeerProject(name: name, placement: inventory.placement, defaultBranch: inventory.defaultBranch,
                           githubRepositories: inventory.githubRepositories,
                           workingChanges: snapshot.workingChanges ?? inventory.workingChanges,
                           branchTips: tips)
    }

    func hasGitHubBranchDifferences(for project: String) -> Bool {
        guard let local = sidebarProject(project), local.placement == .checkedOut,
              let branch = local.defaultBranch, let state = local.branchTips,
              let tip = state.local[branch], let github = state.github[branch] else { return false }
        return tip != github
    }

    func hasBranchDifferences(for project: String) -> Bool {
        let projects = [sidebarProject(project)] + configuration.hosts.map { sidebarProject(project, hostID: $0.id) }
        let checkouts = projects.compactMap { $0 }.filter { $0.placement == .checkedOut }
        guard let branch = checkouts.compactMap(\.defaultBranch).first else { return false }
        if let local = sidebarProject(project), local.placement == .checkedOut,
           let state = local.branchTips, let tip = state.local[branch],
           let github = state.github[branch], github != tip { return true }
        var known: String?
        for state in checkouts.compactMap(\.branchTips) {
            guard let tip = state.local[branch] else { continue }
            if let known, known != tip { return true }
            known = tip
        }
        return false
    }

    func workingChangeCounts(for project: String) -> (additions: Int, deletions: Int)? {
        let projects = [sidebarProject(project)] + configuration.hosts.map { sidebarProject(project, hostID: $0.id) }
        let changes = projects.compactMap { $0?.workingChanges }
            .filter { !$0.isEmpty }
        guard !changes.isEmpty else { return nil }
        return changes.flatMap { $0.files ?? [] }.reduce(into: (additions: 0, deletions: 0)) {
            $0.additions += $1.additions ?? 0
            $0.deletions += $1.deletions ?? 0
        }
    }

    func githubFetchedAt(for project: String) -> Date? {
        let identities = localProjects[project]?.githubRepositories ?? []
        return identities.compactMap { github.fetchedAt?[$0] }.max()
    }

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
                if !helperAvailable { helperAvailable = true }
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

    func setMergedBranchCleanupEnabled(_ enabled: Bool) {
        perform(.setMergedBranchCleanupEnabled(enabled))
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

    var paletteProjects: [String] {
        Set(configuration.folders.map(\.name) + backupItems.map(\.name)).sorted()
    }

    var paletteCommands: [ProjectTerminalCommand] {
        paletteTargets.flatMap { target -> [ProjectTerminalCommand] in
            let host: TerminalHost?
            let directory: URL
            switch target.source {
            case .local:
                guard placement(of: target.project, on: nil) == .checkedOut,
                      let local = repositoryURL(for: target.project) else { return [] }
                host = nil
                directory = local
            case .host(let id):
                guard placement(of: target.project, on: id) == .checkedOut,
                      let remote = terminalHosts.first(where: { $0.id == id.uuidString }) else { return [] }
                host = remote
                directory = URL(fileURLWithPath: remote.directory).appendingPathComponent(target.project)
            case .backup: return []
            }
            return terminals.commandHistory(project: target.project, directory: directory, hosts: terminalHosts, host: host)
        }
    }

    func cancelPaletteCommand() {
        paletteCommandTask?.cancel()
        paletteCommandTask = nil
    }

    var paletteTargets: [PaletteTarget] {
        paletteProjects.flatMap { name -> [PaletteTarget] in
            var targets: [PaletteTarget] = []
            if repositoryURL(for: name) != nil {
                targets.append(PaletteTarget(project: name, source: .local, label: "This Mac", priority: 0))
            }
            let folder = configuration.folders.first { $0.name == name }
            for (index, host) in configuration.hosts.enumerated() where folder?.availableHosts.contains(host.id) == true {
                targets.append(PaletteTarget(project: name, source: .host(host.id), label: host.name, priority: index + 1))
            }
            for (index, snapshot) in (backupItems.first { $0.name == name }?.snapshots ?? []).enumerated() {
                targets.append(PaletteTarget(project: name, source: .backup(snapshot.id),
                    label: "Backup — " + snapshot.machine, priority: configuration.hosts.count + index + 1))
            }
            return targets
        }
    }

    func showPalette(in window: NSWindow? = nil) {
        guard !showingPalette else { return }
        paletteNavigation = UUID()
        paletteWindow = window ?? NSApp.keyWindow
        palettePreviousResponder = paletteWindow?.firstResponder
        guard let content = paletteWindow?.contentView, let container = content.superview else { return }
        showingPalette = true
        let overlay = NSHostingView(rootView: PaletteOverlay(model: self))
        overlay.frame = content.convert(content.bounds, to: container)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // SwiftUI owns its hosting view's rendering subtree. Present alongside it,
        // so its compositing passes cannot cover the palette's native hosting view.
        container.addSubview(overlay, positioned: .above, relativeTo: content)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: content.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        paletteView = overlay
        // Mount the native search field before returning from the menu command.
        overlay.layoutSubtreeIfNeeded()
    }

    func dismissPalette() {
        closePalette(restoringFocus: true)
    }

    private func closePalette(restoringFocus: Bool) {
        cancelPaletteCommand()
        paletteView?.removeFromSuperview()
        paletteView = nil
        showingPalette = false
        paletteNavigation = UUID()
        guard restoringFocus else { return }
        let window = paletteWindow, responder = palettePreviousResponder
        Task { @MainActor in
            await Task.yield()
            if !showingPalette { window?.makeFirstResponder(responder) }
        }
    }

    func insertGitReference(_ value: String) {
        guard let project = selectedProjectName else { NSSound.beep(); return }
        let host: TerminalHost?
        if case .host(let id) = selectedProjectHostSource {
            guard let selected = terminalHosts.first(where: { $0.id == id.uuidString }) else { NSSound.beep(); return }
            host = selected
        } else { host = nil }
        guard placement(of: project, on: host.flatMap { UUID(uuidString: $0.id) }) == .checkedOut,
              let directory = host.map({ URL(fileURLWithPath: $0.directory).appendingPathComponent(project) }) ?? selectedLocalRepositoryURL
        else { NSSound.beep(); return }
        guard terminals.insertReference(gitReferenceArgument(value), project: project, directory: directory, hosts: terminalHosts, host: host)
        else { NSSound.beep(); return }
        selectCommit(nil)
        selectedTab = .terminal
    }

    func gitReferenceArgument(_ value: String) -> String {
        // Graph labels include friendly host names; insert the actual Git ref instead.
        let refs = projectSnapshot?.references ?? []
        let reference = refs.first { ref in
            [false, true].contains { expanded in
                RepositoryReference.graphNames([ref], hosts: configuration.hosts, sourceMachine: projectSourceMachine,
                    allReferences: refs, tags: ref.isGraphTag, localMachine: configuration.machine, expanded: expanded).contains(value)
            } || ref.displayName(hosts: configuration.hosts) == value
        }
        let name = reference.map { $0.fullName.hasPrefix("refs/sync/") ? $0.fullName : $0.name }
            ?? projectSnapshot?.auxiliaryHistoryLabels.first(where: { $0.value.contains(value) })?.key ?? value
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-")
        return name.unicodeScalars.allSatisfy(safe.contains) ? name : "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func openPaletteResult(_ result: PaletteResult) {
        cancelPaletteCommand()
        if let command = result.command {
            paletteCommandTask = Task {
                let prepared = await terminals.prepareCommand(command, hosts: terminalHosts)
                guard !Task.isCancelled else { return }
                guard prepared else { NSSound.beep(); return }
                selectProject(command.project)
                let source: ProjectSource = command.hostID.flatMap(UUID.init(uuidString:)).map(ProjectSource.host) ?? .local
                selectProjectHost(source)
                selectedTab = .terminal
                closePalette(restoringFocus: false)
                await Task.yield()
                guard !showingPalette, selectedProjectName == command.project,
                      selectedTab == .terminal, terminalSource == source else { return }
                terminals.focusPreparedCommand(command)
            }
            return
        }
        selectProject(result.project)
        guard selectedProjectName == result.project else { return }
        guard let match = result.match, let target = result.target else {
            selectCommit(nil)
            selectedTab = .info
            dismissPalette()
            return
        }
        dismissPalette()
        let navigation = UUID()
        paletteNavigation = navigation
        let localURL = repositoryURL(for: result.project)
        let previousTab = selectedTab
        Task {
            let hasLocal = await Task.detached(priority: .userInitiated) {
                localURL.map { (try? Repository(name: result.project, url: $0).commit(at: match.commit.oid)) != nil } ?? false
            }.value
            guard paletteNavigation == navigation, selectedProjectName == result.project,
                  selectedTab == previousTab else { return }
            selectProjectSource(hasLocal ? .local : target.source)
            selectCommit(match.commit.oid)
            paletteCommit = match.commit
            selectedTab = .diff
        }
    }

    nonisolated static func search(_ target: PaletteTarget, query: String,
                                   configuration: AppConfiguration) throws -> [RepositorySearchMatch] {
        switch target.source {
        case .local:
            let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
            return try Repository(name: target.project, url: root.appendingPathComponent(target.project)).search(query).checked()
        case .host(let id):
            guard let host = configuration.hosts.first(where: { $0.id == id }) else {
                throw SyncError.invalidConfiguration("Host is no longer configured")
            }
            return try Runner.projectSearch(target.project, query: query, configuration: remoteConfiguration(host, in: configuration))
        case .backup(let id):
            if let root = try configuration.validatedBackupDestination() {
                return try BackupIndex.search(target.project, snapshotID: id, query: query, from: root).checked()
            }
            guard let host = try configuration.backupHost() else {
                throw SyncError.invalidConfiguration("Backup is unavailable")
            }
            return try Runner.backupSearch(target.project, snapshotID: id, query: query,
                configuration: remoteConfiguration(host, in: configuration, receiveOnly: true))
        }
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
                                            configuration: AppConfiguration, showAuxiliaryHistory: Bool = false) throws -> RepositoryContent {
        switch source {
        case .local:
            let root = URL(fileURLWithPath: NSString(string: configuration.root).expandingTildeInPath)
            return try Repository(name: name, url: root.appendingPathComponent(name)).content(showAuxiliaryHistory: showAuxiliaryHistory)
        case .host(let id):
            guard let host = configuration.hosts.first(where: { $0.id == id }) else {
                throw SyncError.invalidConfiguration("The selected host is no longer configured.")
            }
            return try Runner.projectContent(name, showAuxiliaryHistory: showAuxiliaryHistory, configuration: remoteConfiguration(host, in: configuration))
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
            .appendingPathComponent("Contents/Library/LoginItems/Portal Menu Helper.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    private func launchHelper() -> Bool {
        guard let embeddedHelperURL else { return false }
        guard NSRunningApplication.runningApplications(
            withBundleIdentifier: "dev.mxcl.portal.menu-helper"
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
            withBundleIdentifier: "dev.mxcl.portal.menu-helper"
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
        let oldHelpers = ["dev.mxcl.git-sync.menu", "dev.mxcl.git-sync.menu-helper"].map {
            SMAppService.loginItem(identifier: $0)
        }
        let oldHelperEnabled = oldHelpers.contains { $0.status == .enabled || $0.status == .requiresApproval }
        do {
            for helper in oldHelpers where helper.status == .enabled || helper.status == .requiresApproval {
                try helper.unregister()
            }
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
    @FocusState private var isSidebarFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var isArchivedExpanded = false
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var projectSelection: String?
    @State private var hostPaneWidth: CGFloat = 600
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
                Section {
                    ForEach(projects, id: \.self) { name in
                        ProjectRow(name: name, model: model)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: -4))
                            .listRowSeparator(.hidden)
                            .tag(name)
                    }
                } header: {
                    HStack {
                        Text("PROJECTS")
                        Spacer()
                        HStack(spacing: 0) {
                            Text("B").frame(width: 18).help("Backup activity or error")
                            Text("Δ").frame(width: 18).help("Peer or GitHub branch differences")
                            Text("T").frame(width: 18).help("Terminal activity")
                        }
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color(red: 0.61, green: 0.69, blue: 0.71))
                    // Sidebar section headers have different native margins from rows.
                    .padding(.leading, 2)
                    .padding(.trailing, 10)
                }
                if !archived.isEmpty {
                    Section {
                        if isArchivedExpanded {
                            ForEach(archived) { item in
                                Text(item.name)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .listRowSeparator(.hidden)
                                    .tag(item.name)
                            }
                        }
                    } header: {
                        Button {
                            isArchivedExpanded.toggle()
                        } label: {
                            HStack {
                                Text("Archived")
                                Spacer()
                                Image(systemName: isArchivedExpanded ? "chevron.down" : "chevron.right")
                                    .padding(.trailing, 12)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(isArchivedExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Toggle archived projects")
                    }
                }
            }
            .environment(\.defaultMinListRowHeight, 31)
            .contentMargins(.horizontal, 2, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(DarkSidebarMaterial().ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .navigationTitle("Projects")
            .focused($isSidebarFocused)
            .onChange(of: model.selectedTab, initial: true) { _, tab in
                if tab == .info { isSidebarFocused = true }
            }
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
                .navigationSplitViewColumnWidth(min: 280, ideal: initialGitTreeColumnWidth, max: .infinity)
                .toolbar {
                    // .navigation moves ahead of the floating sidebar on newer macOS.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("Back", systemImage: "chevron.left", action: model.goBack)
                            .disabled(!model.canGoBack)
                            .help("Back (⌘[)")
                        Button("Forward", systemImage: "chevron.right", action: model.goForward)
                            .disabled(!model.canGoForward)
                            .help("Forward (⌘])")
                    }
                }
        } detail: {
            if model.showsCommitDiff {
                ProjectDetailView(model: model)
            } else if let name = model.selectedProjectName {
                HostControls(project: name, model: model)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { hostPaneWidth = $0 }
                    .toolbar {
                        if model.showsProjectHostTabs {
                            ToolbarItem(placement: .primaryAction) {
                                HStack {
                                    Spacer(minLength: 0)
                                    HStack(spacing: 0) {
                                        if !model.projectTerminalSources.isEmpty {
                                            HostTabs(model: model).fixedSize()
                                        }
                                        if !model.projectCheckoutSources.isEmpty {
                                            Menu {
                                                ForEach(model.projectCheckoutSources, id: \.self) { source in
                                                    Button(model.projectSourceLabel(source)) {
                                                        model.selectProjectHost(source)
                                                    }
                                                }
                                            } label: {
                                                Image(systemName: "plus")
                                            }
                                            .menuIndicator(.hidden)
                                            .menuStyle(.borderlessButton)
                                            .fixedSize()
                                            .padding(.horizontal, 8)
                                            .help("Check out on another host")
                                            .accessibilityLabel("Check out on another host")
                                        }
                                    }
                                    .glassEffect()
                                    Spacer(minLength: 0)
                                }
                                .frame(width: max(0, hostPaneWidth - 24))
                            }
                            .sharedBackgroundVisibility(.hidden)
                        }
                    }
            } else {
                ContentUnavailableView("Select a Project", systemImage: "sidebar.left")
            }
        }
        .environment(\.insertGitReference, model.insertGitReference)
        .navigationSplitViewStyle(.balanced)
        // Use the system Copy command so text responders take priority and Edit flashes.
        .copyable(model.selectedCommit.map { [$0.oid] } ?? [])
        .frame(minWidth: 860, minHeight: 520)
        .overlay {
            if !model.helperAvailable {
                HelperUnavailableView(model: model)
            }
        }
        .disabled(model.showingPalette)
        .accessibilityHidden(model.showingPalette)
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
        .sheet(item: $model.checkoutRequest) { request in
            BranchPicker(request: request, model: model)
        }
        .sheet(item: $model.renameRequest) { request in
            RenameProgressSheet(request: request, model: model)
        }
        .onOpenURL { url in
            if url.scheme == "portal", url.host == "palette" {
                NotificationCenter.default.post(name: EngineControlProtocol.showPaletteNotification, object: nil)
            } else if ["portal", "gitsync"].contains(url.scheme ?? ""), url.host == "github-connected" {
                model.githubAction(.refresh)
                openSettings()
                NSApplication.shared.activate()
            } else if ["portal", "gitsync"].contains(url.scheme ?? ""), url.host == "settings" {
                openSettings()
                NSApplication.shared.activate()
            } else if model.openProjectURL(url) {
                NSApplication.shared.activate()
            }
        }
    }

}

private struct RenameProgressSheet: View {
    let request: ProjectRename.Record
    @ObservedObject var model: AppModel

    private var message: String {
        if model.cancellingRename { return "Requesting cancellation…" }
        switch model.renameProgress {
        case .checking: return "Checking hosts and backup…"
        case .cancelling: return "Cancelling after the current check…"
        case .renaming: return "Renaming backup and project folders…"
        case nil: return "Connecting to Sync Helper…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Renaming \(request.old)").font(.headline)
            Text("New name: \(request.new)").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(message)
            }
            Text(model.renameProgress == .renaming
                 ? "Finishing safely. This step can’t be cancelled."
                 : "Keep this window open until the operation finishes.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelRename)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.renameProgress != .checking || model.cancellingRename)
            }
        }
        .padding(24)
        .frame(width: 400)
        .interactiveDismissDisabled()
    }
}

private struct DarkSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = makeTerminalBackgroundView()
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.appearance = NSAppearance(named: .darkAqua)
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

struct ProjectRow: View {
    let name: String
    @ObservedObject var model: AppModel

    @ObservedObject private var terminals: TerminalWorkspace

    init(name: String, model: AppModel) {
        self.name = name
        self.model = model
        self.terminals = model.terminals
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.83, green: 0.87, blue: 0.88))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let counts = model.workingChangeCounts(for: name) {
                        (Text("+\(counts.additions)").foregroundColor(.green)
                         + Text(" −\(counts.deletions)").foregroundColor(.red))
                            .help("Uncommitted changes across hosts: \(counts.additions) additions, \(counts.deletions) deletions")
                    }
                    if let counts = model.githubCounts(for: name) {
                        if counts.stars > 0 { Text("☆\(counts.stars.formatted(.number.notation(.compactName)))").help("GitHub stars") }
                        if counts.pullRequests > 0 { Text("↟\(counts.pullRequests)").help("Open GitHub pull requests") }
                        if counts.issues > 0 { Text("ⓘ\(counts.issues)").help("Open GitHub issues") }
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(red: 0.49, green: 0.59, blue: 0.62))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                SidebarLED(tone: backupFailed ? .red : backupTransferring ? .white : .off,
                           label: model.backupSidebarStatus(for: name), transferring: backupTransferring)
                SidebarLED(tone: model.hasGitHubBranchDifferences(for: name) ? .amber
                           : model.hasBranchDifferences(for: name) ? .white : .off,
                           label: model.hasGitHubBranchDifferences(for: name) ? "Default branch differs from GitHub"
                           : model.hasBranchDifferences(for: name) ? "Default branch differs across checked-out hosts"
                           : "No known default branch differences",
                           outputAt: model.githubFetchedAt(for: name), outputMaxAge: 5)
                SidebarLED(tone: terminalTone, label: terminalLabel, outputAt: terminals.projectOutputAt[name])
            }
        }
        .frame(minHeight: 29)
        .help(projectSummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(projectSummary + " — " + terminalLabel)
    }

    private var backupFailed: Bool {
        model.configuration.backup != nil || model.configuration.backupDestination != nil
            ? model.backupError != nil || model.helperError != nil || model.error != nil : false
    }

    private var backupTransferring: Bool {
        !backupFailed && !model.isPaused && model.isRunning && model.backupTransferring[name] == true
    }

    private var terminalTone: SidebarLED.Tone {
        Self.terminalTone(state: terminals.projectTerminalStates[name], activity: terminals.projectActivities[name])
    }

    static func terminalTone(state: TerminalWorkspace.TerminalState?, activity: TerminalWorkspace.Activity?) -> SidebarLED.Tone {
        if state == .active { return .white }
        return activity == .unviewed ? .blue : .off
    }

    private var terminalLabel: String {
        if terminalTone == .blue { return "Terminal command finished while away — view its terminal to clear" }
        return switch terminals.projectTerminalStates[name] {
        case .active: "Terminal active — flashes on received output"
        case .waiting: "Terminal waiting for input"
        case nil: "No active terminal"
        }
    }

    private var projectSummary: String {
        guard let folder = model.configuration.folders.first(where: { $0.name == name }) else { return name }
        let count = (folder.availableLocally ? 1 : 0) + folder.availableHosts.count
        let github = model.githubCounts(for: name).map { " — " + $0.summary } ?? ""
        let changes = model.workingChangeCounts(for: name).map {
            " — uncommitted changes: \($0.additions) additions, \($0.deletions) deletions across hosts"
        } ?? ""
        let branches = model.hasBranchDifferences(for: name)
            ? " — default branch differs across checked-out hosts or from this Mac’s known GitHub state" : ""
        return "\(name) — on \(count) host\(count == 1 ? "" : "s")\(changes)\(branches)\(github) — \(model.backupSidebarStatus(for: name))"
    }
}

private struct ProjectHistoryView: View {
    @ObservedObject var model: AppModel
    @FocusState private var isFocused: Bool
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
                    get: { model.selectedStagingRowID }, set: model.selectCommit
                ))
                .focused($isFocused)
            } else {
                ContentUnavailableView("No Available Copy", systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                                       description: Text("Bring this project to a configured host to render its Git tree and README."))
            }
        }
        .navigationTitle(model.selectedProjectName ?? "Git Tree")
        .onChange(of: model.selectedProjectName, initial: true) { _, _ in
            if model.selectedTab == .diff { isFocused = true }
        }
        .onChange(of: model.selectedTab) { _, tab in
            if tab == .diff { isFocused = true }
        }


    }
}

private struct CommitList: View {
    @Environment(\.insertGitReference) private var insertReference
    @State private var hoveredLabel: Int?
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
        let branchRefs = Dictionary(grouping: snapshot.references.filter(\.isGraphBranch), by: \.oid)
        var labels = branchRefs.mapValues { RepositoryReference.graphNames($0, hosts: hosts, sourceMachine: sourceMachine,
                                                       allReferences: snapshot.references, localMachine: localMachine) }
        var hoverLabels = branchRefs.mapValues {
            RepositoryReference.graphNames($0, hosts: hosts, sourceMachine: sourceMachine, expanded: true)
        }
        labels.merge(snapshot.auxiliaryHistoryLabels) { $0 + $1 }
        hoverLabels.merge(snapshot.auxiliaryHistoryLabels) { $0 + $1 }
        graph = CommitGraphGenerator.generate(
            commits: rows, headOID: headOID, branchNames: labels, hoverBranchNames: hoverLabels,
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
                              allReferences: snapshot.references,
                              auxiliaryLabels: snapshot.auxiliaryHistoryLabels[commit.oid] ?? [],
                              hosts: hosts, sourceMachine: sourceMachine, graph: graph, rowIndex: index,
                              hoveredLabel: $hoveredLabel)
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
                Label("\(error.host) staging unavailable. Retrying automatically.", systemImage: "exclamationmark.triangle")
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
            let files = checkout.checkouts.flatMap { $0.snapshot.workingChanges?.files ?? [] }
            let additions = files.reduce(0) { $0 + ($1.additions ?? 0) }
            let deletions = files.reduce(0) { $0 + ($1.deletions ?? 0) }
            let hosts = checkout.checkouts.map(\.host).joined(separator: ", ")
            let status = checkout.checkouts.map { item in
                let changes = item.snapshot.workingChanges
                return "\(item.host): \(changes?.isEmpty == true ? "Clean" : changes?.summary ?? "Unavailable")"
            }.joined(separator: "\n")
            HStack(alignment: .top, spacing: 8) {
                BranchGraphRowCanvas(model: graph, rowIndex: index, commitOID: checkout.id, hoveredLabel: $hoveredLabel, onInsertReference: insertReference)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Staging").fixedSize()
                        Text(hosts).font(.caption).foregroundStyle(.secondary)
                        if checkout.checkouts.count > 1 && !files.isEmpty {
                            HStack(spacing: 4) {
                                Text("+\(additions)").foregroundStyle(.green)
                                Text("−\(deletions)").foregroundStyle(.red)
                            }.font(.caption.monospacedDigit()).fixedSize()
                        } else if !changes.isEmpty {
                            Text(changes.summary).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.lineLimit(1)
                    Text(checkout.checkouts.count == 1 ? stagingPaths(changes) : AttributedString(files.isEmpty ? "Clean" : files.map(\.path).joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(([status] + files.map { file in
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
    @Environment(\.insertGitReference) private var insertReference
    let commit: RepositoryCommit
    let isCurrent: Bool
    let references: [RepositoryReference]
    let allReferences: [RepositoryReference]
    let auxiliaryLabels: [String]
    let hosts: [SyncHost]
    let sourceMachine: String?
    let graph: CommitGraphModel
    let rowIndex: Int
    @Binding var hoveredLabel: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BranchGraphRowCanvas(model: graph, rowIndex: rowIndex, commitOID: commit.oid, hoveredLabel: $hoveredLabel, onInsertReference: insertReference)
            VStack(alignment: .leading, spacing: 4) {
                Text(commit.subject).lineLimit(1)
                HStack {
                    Text(commit.author)
                    CommitSHA(sha: commit.oid)
                    ForEach(RepositoryReference.graphNames(references, hosts: hosts, sourceMachine: sourceMachine,
                                                          allReferences: allReferences, tags: true), id: \.self) { tag in
                        Button { insertReference(tag) } label: {
                            Label(tag, systemImage: "tag")
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        }.buttonStyle(.plain)
                            .help("Insert \(tag) into terminal")
                    }
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
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            ForEach(RepositoryReference.graphNames(references, hosts: hosts, sourceMachine: sourceMachine,
                allReferences: allReferences), id: \.self) { name in
                Button("Insert \(name) into terminal") { insertReference(name) }
            }
        }
        .help((RepositoryReference.graphNames(references, hosts: hosts, sourceMachine: sourceMachine, allReferences: allReferences, expanded: true) + auxiliaryLabels).joined(separator: "\n"))
        .accessibilityValue(([isCurrent ? "Checked out commit" : ""] +
            RepositoryReference.graphNames(references, hosts: hosts, sourceMachine: sourceMachine, allReferences: allReferences, expanded: true) + auxiliaryLabels).filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

private struct InsertGitReferenceKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in NSSound.beep() }
}

extension EnvironmentValues {
    var insertGitReference: (String) -> Void {
        get { self[InsertGitReferenceKey.self] }
        set { self[InsertGitReferenceKey.self] = newValue }
    }
}

struct CommitSHA: View {
    let sha: String
    @Environment(\.insertGitReference) private var insertReference

    var body: some View {
        Button { insertReference(sha) } label: {
            Text(sha.prefix(8)).monospaced()
                .padding(.horizontal, 5).padding(.vertical, 1)
        }
        .buttonStyle(.plain)
        .help("Insert commit SHA into terminal: \(sha)")
        .accessibilityLabel("Insert commit SHA into terminal")
        .accessibilityValue(sha)
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
            } else if let commit = model.selectedCommit {
                CommitDetail(commit: commit,
                             references: model.projectSnapshot?.references ?? [],
                             sourceMachine: model.projectSourceMachine,
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
                if let archived = model.archivedProjects.first(where: { $0.name == name }) {
                    ArchivedProjectControls(item: archived, model: model)
                }
                Divider()
                if let readme = model.projectReadme {
                    HStack {
                        Text("README").font(.headline)
                        Spacer()
                        Text(readme.source).font(.caption).foregroundStyle(.secondary)
                            .help(model.projectSource.map { "From \(model.projectSourceLabel($0))" } ?? readme.source)
                            .accessibilityValue(model.projectSource.map(model.projectSourceLabel) ?? readme.source)
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
}

@MainActor
private struct HostTabs: NSViewRepresentable {
    @ObservedObject var model: AppModel

    private var sources: [ProjectSource] { model.projectTerminalSources }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectHost(_:))
        control.setAccessibilityLabel("Host")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.sources = sources
        control.segmentCount = sources.count
        for (index, source) in sources.enumerated() {
            let host = model.configuration.hosts.first { .host($0.id) == source }
            let name = host?.name ?? model.configuration.machine
            let hardware = host?.hardware ?? (source == .local ? .current : nil)
            let type = hardware?.operatingSystem == "Linux" ? HostIcon.macType(for: "RackMount")
                : hardware?.model.flatMap { HostIcon.macType(for: $0) }
            let image = type.map { NSWorkspace.shared.icon(for: $0).copy() as! NSImage }
                ?? NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            image?.size = NSSize(width: 16, height: 16)
            control.setLabel(name, forSegment: index)
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setToolTip(name, forSegment: index)
        }
        control.selectedSegment = sources.firstIndex(of: model.selectedProjectHostSource) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let width = (0..<nsView.segmentCount).map { index in
            (nsView.label(forSegment: index) as NSString? ?? "").size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width + 48
        }.max() ?? 100
        return CGSize(width: width * CGFloat(nsView.segmentCount), height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: AppModel
        var sources: [ProjectSource] = []
        init(model: AppModel) { self.model = model }

        @objc func selectHost(_ control: NSSegmentedControl) {
            guard sources.indices.contains(control.selectedSegment) else { return }
            model.selectProjectHost(sources[control.selectedSegment])
        }
    }
}

private struct HostControls: View {
    let project: String
    @ObservedObject var model: AppModel


    private var hostID: UUID? {
        if case .host(let id) = model.selectedProjectHostSource { return id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(8)
            }
            if model.placement(of: project, on: hostID) == .checkedOut {
                if let hostID, let host = model.terminalHosts.first(where: { $0.id == hostID.uuidString }) {
                    model.terminals.view(project: project, directory: URL(fileURLWithPath: host.directory).appendingPathComponent(project),
                                         hosts: model.terminalHosts, host: host)
                } else if hostID == nil, let directory = model.selectedLocalRepositoryURL {
                    model.terminals.view(project: project, directory: directory, hosts: model.terminalHosts)
                }
            } else if let archived = model.archivedProjects.first(where: { $0.name == project }) {
                ArchivedProjectControls(item: archived, model: model)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var status: some View {
        let placement = model.placement(of: project, on: hostID)
        let name = hostID.flatMap { id in model.configuration.hosts.first { $0.id == id }?.name }
            ?? model.configuration.machine
        let status = model.placementStatus(for: project, on: hostID, placement: placement)
        return VStack(spacing: 12) {
            Text(name).font(.title2)
            Text(status.isEmpty ? placement.title : status).foregroundStyle(.secondary)
            if model.placementInProgress == (hostID?.uuidString ?? "local") {
                ProgressView().accessibilityLabel("Updating \(name)")
            }
            HStack {
                switch placement {
                case .notPresent:
                    Button("Mirror") { model.setPlacement(.mirrored, project: project, hostID: hostID) }
                    if hostID == nil { Button("Check Out") { model.checkOut(project, hostID: nil) } }
                case .mirrored:
                    Button("Check Out") { model.checkOut(project, hostID: hostID) }
                    Button("Move to Trash", role: .destructive) {
                        model.setPlacement(.notPresent, project: project, hostID: hostID)
                    }
                case .unknown, .checkedOut: EmptyView()
                }
            }
            .disabled(model.placementInProgress != nil)
        }
        .padding()
    }
}

private extension ProjectPlacement {
    var title: String {
        switch self {
        case .checkedOut: "Checked out"
        case .mirrored: "Mirrored"
        case .notPresent: "Not Present"
        case .unknown: "Unavailable"
        }
    }
}

private struct CommitDetail: View {
    @Environment(\.insertGitReference) private var insertReference
    let commit: RepositoryCommit
    let references: [RepositoryReference]
    let sourceMachine: String?
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

    private var referenceNames: [String] {
        let refs = references.filter { $0.oid == commit.oid }
        return RepositoryReference.graphNames(refs, hosts: hosts, sourceMachine: sourceMachine,
                                              allReferences: references)
            + RepositoryReference.graphNames(refs, hosts: hosts, sourceMachine: sourceMachine,
                                             allReferences: references, tags: true)
            + refs.filter { !$0.isGraphBranch && !$0.isGraphTag }.map { $0.displayName(hosts: hosts) }
    }

    private var identifiers: some View {
        Group {
            HStack {
                Text("Commit").foregroundStyle(.secondary)
                CommitSHA(sha: commit.oid)
            }
            if !commit.parents.isEmpty {
                HStack(alignment: .top) {
                    Text(commit.parents.count == 1 ? "Parent" : "Parents").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        ForEach(commit.parents, id: \.self) { CommitSHA(sha: $0) }
                    }
                }
            }
            if !referenceNames.isEmpty {
                ForEach(referenceNames, id: \.self) { name in
                    Button { insertReference(name) } label: {
                        Label(name, systemImage: "point.3.connected.trianglepath.dotted")
                    }.buttonStyle(.plain).help("Insert \(name) into terminal")
                }
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

    private var destination: String { model.projectSourceLabel(model.selectedProjectHostSource) }

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
                ProgressView("Restoring project…")
            } else if item.snapshots.count == 1, let snapshot = item.snapshots.first {
                Button("Bring to \(destination)") { model.unarchiveBackup(item, snapshot: snapshot) }
                    .disabled(model.deletingBackup != nil || model.restoringBackup != nil || model.placementInProgress != nil)
            } else if !item.snapshots.isEmpty {
                Menu("Bring to \(destination)") {
                    ForEach(item.snapshots) { snapshot in
                        Button("From \(snapshot.machine)") { model.unarchiveBackup(item, snapshot: snapshot) }
                    }
                }
                .disabled(model.deletingBackup != nil || model.restoringBackup != nil || model.placementInProgress != nil)
            }
            Button("Delete Backup…", role: .destructive) { model.deleteBackup(item) }
                .disabled(model.deletingBackup != nil || model.restoringBackup != nil)
                .help("Permanently delete this project’s stored repository and all backup snapshots.")
            if model.deletingBackup == item.name { ProgressView("Deleting backup…") }
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
            RemoteAccessSettings(model: model.remoteAccess)
                .tabItem { Label("Remote Access", systemImage: "network") }
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
                    Toggle("Launch Portal at login", isOn: Binding(get: { model.launchesAtLogin }, set: model.setLaunchAtLogin))
                    if model.launchAtLoginRequiresApproval {
                        Button("Open Login Items…", action: model.openLoginItems)
                    }
                }
                Section("Keyboard Shortcut") {
                    Toggle("Open Portal with ⌘⌥`", isOn: Binding(
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
                Section("Command Line") {
                    Button("Install Command Line Tool…") {
                        guard let script = Bundle.main.url(forResource: "install-portal", withExtension: "command"),
                              NSWorkspace.shared.open(script) else {
                            let alert = NSAlert()
                            alert.messageText = "Could not open the command line installer"
                            alert.informativeText = "Reinstall Portal and try again."
                            alert.runModal()
                            return
                        }
                    }
                }
                Section("Terminal") {
                    Button("Become Default Terminal App") {
                        Task { @MainActor in
                            do {
                                for type in [UTType.unixExecutable, UTType(importedAs: "com.apple.terminal.shell-script")] {
                                    try await NSWorkspace.shared.setDefaultApplication(at: TerminalApplication.url, toOpen: type)
                                }
                            } catch { NSAlert(error: error).runModal() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Section("GitHub") {
                    LabeledContent("Connection", value: model.github.status)
                    HStack {
                        if model.github.connected {
                            Button("Repository Access…") { model.githubAction(.installations) }
                                .disabled(model.github.installationURL == nil)
                            Button("Disconnect") { model.githubAction(.disconnect) }
                        } else {
                            Button("Connect GitHub…") { model.githubAction(.connect) }
                        }
                    }
                    if let error = model.github.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section("Merged Branches") {
                    Toggle("Automatically delete merged branches", isOn: Binding(
                        get: { model.mergedBranchCleanupEnabled }, set: model.setMergedBranchCleanupEnabled
                    ))
                    Text("On this Mac, delete merged branches only after their history is permanently backed up. Branches with new commits or active checkouts are kept. Includes squash and rebase merges.")
                        .foregroundStyle(.secondary)
                }
                Section("Notifications") {
                    LabeledContent("Push updates", value: model.github.pushStatus)
                    LabeledContent("Banners", value: model.github.notificationPermission)
                    Button("Allow Notifications…") { model.githubAction(.requestNotificationPermission) }
                    Text("Notifications cover tracked GitHub projects. Stars and open PR/issue counts appear in the sidebar.")
                        .foregroundStyle(.secondary)
                    Text("Updates arrive through push notifications, with catch-up on launch and reconnect. Unread notifications are checked every minute and after opening a notification.")
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
            Text("This changes how the host appears in Portal, not its Git identity.")
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
                TextField("portald executable", text: $model.hostDraft.executable)
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
@main enum PortalApp { static func main() { print("Portal.app is available on macOS only") } }
#endif
