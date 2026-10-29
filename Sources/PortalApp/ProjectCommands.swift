#if os(macOS)
import SwiftUI
import PortalTerminal

struct ProjectCommands: Commands {
    @FocusedValue(\.paletteModel) private var model

    var body: some Commands {
        CommandGroup(before: .newItem) {
            Button("Switch Project…") { model?.showPalette() }
                .keyboardShortcut("p")
                .disabled(model == nil)
            Divider()
            Button("Reveal in Finder") { model?.revealSelectedProjectInFinder() }
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open in Terminal") { model?.openSelectedProjectInTerminal() }
                .keyboardShortcut("t")
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open in External Editor") { model?.openSelectedProjectInEditor() }
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open on GitHub") { model?.openSelectedProjectOnGitHub() }
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
    @FocusedValue(\.paletteModel) private var model
    let workspace: TerminalWorkspace

    var body: some Commands {
        TerminalCommands(workspace: workspace,
                         enabled: model.map { $0.selectedTab == .terminal && !$0.showsCommitDiff
                             && $0.projectTerminalSources.contains($0.selectedProjectHostSource) } ?? false,
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
            titledMenuItem = item
            titledSubmenu = submenu
            // Menu tracking can reset either title without an application or menu-item update.
            titleObservations = [
                item.observe(\.title) { [weak menu] _, _ in
                    MainActor.assumeIsolated {
                        if let menu { Self.nameProjectMenu(in: menu) }
                    }
                },
                submenu.observe(\.title) { [weak menu] _, _ in
                    MainActor.assumeIsolated {
                        if let menu { Self.nameProjectMenu(in: menu) }
                    }
                }
            ]
        }
        if item.title != "Project" { item.title = "Project" }
        if submenu.title != "Project" { submenu.title = "Project" }
    }
}
#endif
