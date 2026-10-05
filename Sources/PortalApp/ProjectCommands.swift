#if os(macOS)
import SwiftUI
import PortalTerminal

struct ProjectCommands: Commands {
    @FocusedValue(\.paletteModel) private var model

    private var archiveTitle: String {
        guard let model else { return "Archive…" }
        return "Archive on \(model.projectSourceLabel(model.selectedProjectHostSource))…"
    }

    var body: some Commands {
        CommandMenu("Project") {
            Button("Switch Project…") { model?.showPalette() }
                .keyboardShortcut("p")
                .disabled(model == nil)
            Divider()
            Button("Reveal in Finder") { model?.revealSelectedProjectInFinder() }
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open in Terminal") { model?.openSelectedProjectInTerminal() }
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open in External Editor") { model?.openSelectedProjectInEditor() }
                .disabled(model?.selectedLocalRepositoryURL == nil)
            Button("Open on GitHub") { model?.openSelectedProjectOnGitHub() }
                .disabled(model?.projectGitHubURL == nil)
            Divider()
            Button(archiveTitle) { model?.archiveSelectedProject() }
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
            ForEach([ProjectTab.terminal, .editor, .diff, .info]) { tab in
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
                         enabled: model.map { !$0.showsCommitDiff && $0.selectedTab != .editor
                             && $0.projectTerminalSources.contains($0.selectedProjectHostSource) } ?? false,
                         hosts: model?.terminalHosts ?? [],
                         newWindow: { TerminalApplication.open() },
                         newSSHWindow: { TerminalApplication.open(hostID: $0.id) },
                         nextProjectTerminal: model.flatMap { model in
                             model.projectTerminalSources.isEmpty ? nil : { model.showNextProjectTerminal() }
                         })
    }
}
#endif
