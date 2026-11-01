#if os(macOS)
import SwiftUI
import PortalTerminal

struct ProjectNavigation {
    let previous: String?
    let next: String?

    init(projects: [String], selected: String?) {
        guard let selected, let index = projects.firstIndex(of: selected) else {
            previous = projects.last
            next = projects.first
            return
        }
        previous = index > projects.startIndex ? projects[index - 1] : nil
        next = index + 1 < projects.endIndex ? projects[index + 1] : nil
    }
}

extension FocusedValues {
    @Entry var projectNavigation: ProjectNavigation?
    @Entry var projectTerminalCommandsEnabled: Bool?
}

struct ProjectCommands: Commands {
    @FocusedValue(\.paletteModel) private var model
    @FocusedValue(\.projectNavigation) private var navigation

    var body: some Commands {
        CommandGroup(before: .newItem) {
            Button("Switch Project…") { model?.showPalette() }
                .keyboardShortcut("p")
                .disabled(model == nil)
            Button("Previous Project") { model?.selectProject(navigation?.previous) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(navigation?.previous == nil)
            Button("Next Project") { model?.selectProject(navigation?.next) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(navigation?.next == nil)
            Divider()
            Button("Reveal in Finder") { model?.revealSelectedProjectInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open in Terminal") { model?.openSelectedProjectInTerminal() }
                .keyboardShortcut("t")
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open in External Editor") { model?.openSelectedProjectInEditor() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open on GitHub") { model?.openSelectedProjectOnGitHub() }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(model?.projectGitHubURL == nil)
            Divider()
            Button("Rename…") { model?.renameSelectedProject() }
                .disabled(model?.selectedProjectName == nil || model?.placementInProgress != nil)
            Button("Archive…") { model?.archiveSelectedProject() }
                .disabled(model?.canArchiveSelectedProject != true)
        }
    }
}

struct ProjectViewCommands: Commands {
    @FocusedValue(\.paletteModel) private var model

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Back") { model?.goBack() }
                .keyboardShortcut("[")
                .disabled(model?.canGoBack != true)
            Button("Forward") { model?.goForward() }
                .keyboardShortcut("]")
                .disabled(model?.canGoForward != true)
            Divider()
            Toggle("Show Auxiliary History", isOn: Binding(
                get: { model?.showAuxiliaryHistory ?? false },
                set: { model?.showAuxiliaryHistory = $0 }
            ))
            .disabled(model == nil)
            Divider()
            ForEach([ProjectTab.terminal, .diff, .info]) { tab in
                Button("Show \(tab.title)") { model?.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(tab.rawValue.first!), modifiers: [.command, .option])
                    .disabled(model?.availableTabs.contains(tab) != true)
            }
            Divider()
            Button("Next Staging") { model?.selectNextStaging() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model?.stagingRows.isEmpty != false)
        }
    }
}

struct ProjectTerminalCommands: Commands {
    @FocusedValue(\.projectTerminalCommandsEnabled) private var enabled
    @FocusedValue(\.paletteModel) private var model
    let workspace: TerminalWorkspace

    var body: some Commands {
        TerminalCommands(workspace: workspace,
                         enabled: enabled ?? false,
                         hosts: model?.terminalHosts ?? [],
                         newWindow: { TerminalApplication.open() },
                         newSSHWindow: { TerminalApplication.open(hostID: $0.id) },
                         nextProjectTerminal: model.flatMap { model in
                             model.projectTerminalSources.isEmpty ? nil : { model.showNextProjectTerminal() }
                         })
    }
}

extension AppDelegate {
    func applicationWillUpdate(_ notification: Notification) {
        guard let menu = NSApp.mainMenu else { return }
        Self.nameProjectMenu(in: menu)
    }

    private static var isNamingProjectMenu = false
    private static weak var titledMainMenu: NSMenu?
    private static weak var titledMenuItem: NSMenuItem?
    private static weak var titledSubmenu: NSMenu?
    private static var titleObservations: [NSKeyValueObservation] = []

    static func nameProjectMenu(in menu: NSMenu) {
        guard !isNamingProjectMenu else { return }
        isNamingProjectMenu = true
        defer { isNamingProjectMenu = false }
        // SwiftUI owns menu positions; moving its items breaks command reconciliation.
        guard let item = menu.items.first(where: {
            $0.title == "File" || $0.title == "Project" || $0.submenu?.title == "File"
        }), let submenu = item.submenu else { return }
        if titledMenuItem !== item || titledSubmenu !== submenu {
            titledMainMenu = menu
            titledMenuItem = item
            titledSubmenu = submenu
            // Menu tracking can reset either title without an application or menu-item update.
            titleObservations = [
                item.observe(\.title) { _, _ in
                    MainActor.assumeIsolated {
                        if let menu = Self.titledMainMenu { Self.nameProjectMenu(in: menu) }
                    }
                },
                submenu.observe(\.title) { _, _ in
                    MainActor.assumeIsolated {
                        if let menu = Self.titledMainMenu { Self.nameProjectMenu(in: menu) }
                    }
                }
            ]
        }
        if item.title != "Project" { item.title = "Project" }
        if submenu.title != "Project" { submenu.title = "Project" }
    }
}
#endif
