#if os(macOS)
import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditLanguages
import GitSyncCore
import gitdiff

enum ProjectTab: String, CaseIterable, Identifiable {
    case info, diff, terminal, editor
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .diff: "plus.forwardslash.minus"
        case .terminal: "terminal"
        case .editor: "curlybraces"
        }
    }
}

struct FileNode: Identifiable {
    let id: String
    let name: String
    var children: [FileNode]?

    static func tree(_ paths: [String], prefix: String = "") -> [FileNode] {
        let groups = Dictionary(grouping: paths) { $0.split(separator: "/", maxSplits: 1).first.map(String.init) ?? $0 }
        return groups.map { name, paths in
            let id = prefix + name
            let descendants = paths.compactMap { path -> String? in
                guard let slash = path.firstIndex(of: "/") else { return nil }
                return String(path[path.index(after: slash)...])
            }
            return FileNode(id: id, name: name,
                            children: descendants.isEmpty ? nil : tree(descendants, prefix: id + "/"))
        }.sorted {
            if ($0.children == nil) != ($1.children == nil) { return $0.children != nil }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

@MainActor
final class ProjectEditor: ObservableObject {
    @Published private(set) var repository: URL?
    @Published private(set) var files: [RepositoryFile] = []
    @Published private(set) var nodes: [FileNode] = []
    @Published private(set) var path: String?
    @Published var text = ""
    @Published var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var revision = 0
    private var document: RepositoryTextFile?
    private var loadID = UUID()
    private var refreshID = UUID()

    var isDirty: Bool { document.map { !text.utf8.elementsEqual($0.text.utf8) } ?? false }
    var canEdit: Bool { document != nil }

    func connect(_ url: URL?) {
        guard repository != url else { return }
        repository = url
        document = nil
        path = nil
        text = ""
        files = []
        nodes = []
        error = nil
        isLoading = false
        loadID = UUID()
        refresh()
    }

    func refresh() {
        refreshID = UUID()
        let id = refreshID
        guard let repository else { return }
        isLoading = true
        Task {
            do {
                let files = try await Task.detached(priority: .userInitiated) {
                    try Repository(name: repository.lastPathComponent, url: repository).files()
                }.value
                guard refreshID == id else { return }
                self.files = files
                nodes = FileNode.tree(files.map(\.path))
                revision += 1
                isLoading = false
            } catch {
                guard refreshID == id else { return }
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func open(_ path: String, reload: Bool = false) {
        guard let repository, (path != self.path || reload), confirmDiscard() else { return }
        loadID = UUID()
        let id = loadID
        self.path = path
        document = nil
        text = ""
        error = nil
        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try RepositoryTextFile(repository: repository, path: path)
                }.value
                guard loadID == id else { return }
                self.document = document
                text = document.text
            } catch {
                guard loadID == id else { return }
                self.error = error.localizedDescription
            }
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let document else { return false }
        do {
            self.document = try document.save(text)
            error = nil
            refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func discard() {
        text = document?.text ?? ""
    }

    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(path ?? "this file")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn:
            discard()
            return true
        default: return false
        }
    }
}

struct EditorCommands: Commands {
    @ObservedObject var editor: ProjectEditor
    var body: some Commands {
        // SwiftUI's save group also contains Close; preserve the standard commands.
        CommandGroup(after: .saveItem) {
            Button("Save") { editor.save() }.keyboardShortcut("s").disabled(!editor.isDirty)
        }
    }
}

/// Keep SwiftUI's window delegate intact so project URLs can open and reuse the window.
struct EditorCloseGuard: ViewModifier {
    @ObservedObject var editor: ProjectEditor
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.dismissalConfirmationDialog("Save changes to \(editor.path ?? "this file")?",
                                            shouldPresent: editor.isDirty) {
            // Cancel automatic dismissal; only close after saving succeeds.
            Button("Save", role: .cancel) {
                if editor.save() {
                    // Let the confirmation dialog finish cancelling its dismissal first.
                    DispatchQueue.main.async { dismiss() }
                }
            }
            .keyboardShortcut(.defaultAction)
            Button("Don’t Save", role: .destructive) { editor.discard() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your changes will be lost if you don’t save them.")
        }
    }
}

struct ProjectFileBrowser: View {
    @ObservedObject var editor: ProjectEditor
    @State private var search = ""
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter files", text: $search).textFieldStyle(.roundedBorder).padding(8)
            List(search.isEmpty ? editor.nodes : FileNode.tree(editor.files.filter {
                $0.path.localizedCaseInsensitiveContains(search)
            }.map(\.path)), children: \.children,
                 selection: $selection) { node in
                row(node).selectionDisabled(node.children != nil)
            }
            .overlay {
                if editor.isLoading && editor.files.isEmpty { ProgressView("Reading files…") }
                else if editor.files.isEmpty { Text("No files").foregroundStyle(.secondary) }
            }
            Divider()
            HStack {
                Label("Staged", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Unstaged", systemImage: "circle.fill").foregroundStyle(.orange)
            }.font(.caption).padding(8)
        }
        .navigationTitle("Files — This Mac")
        .onAppear { selection = editor.path }
        .onChange(of: editor.path) { _, path in selection = path }
        .onChange(of: selection) { _, path in
            guard let path, path != editor.path else { return }
            Task { @MainActor in
                editor.open(path)
                selection = editor.path // Cancel restores the highlight as well as the document.
            }
        }
    }

    private func row(_ node: FileNode) -> some View {
        let status = editor.files.first { $0.path == node.id }
        return HStack {
            Label(node.name, systemImage: node.children == nil ? "doc.text" : "folder")
                .lineLimit(1).help(node.id)
            Spacer(minLength: 4)
            if status?.isConflicted == true {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Conflicted")
                    .accessibilityLabel("Conflicted")
            }
            if status?.isStaged == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Staged")
                    .accessibilityLabel("Staged")
            }
            if status?.isUnstaged == true {
                Image(systemName: status?.isUntracked == true ? "questionmark.circle" : "circle.fill")
                    .foregroundStyle(.orange).help(status?.isUntracked == true ? "Untracked" : "Unstaged")
                    .accessibilityLabel(status?.isUntracked == true ? "Untracked" : "Unstaged")
            }
        }
    }
}

struct ProjectEditorView: View {
    @ObservedObject var editor: ProjectEditor
    @State private var state = SourceEditorState()
    @State private var presentation = "Edit"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if let path = editor.path {
                HStack {
                    Text(path).lineLimit(1).truncationMode(.middle).help(path)
                    if editor.isDirty { Text("Edited").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Reload") { editor.open(path, reload: true) }
                    Button("Save") { editor.save() }.disabled(!editor.isDirty)
                }.padding(10)
                Picker("File view", selection: $presentation) {
                    Text("Edit").tag("Edit")
                    Text("Unstaged Diff").tag("Unstaged")
                    Text("Staged Diff").tag("Staged")
                }.pickerStyle(.segmented).padding([.horizontal, .bottom], 10)
                if let error = editor.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                Divider()
                if presentation != "Edit", let repository = editor.repository {
                    WorkingFileDiff(repository: repository, path: path, staged: presentation == "Staged",
                                    revision: editor.revision)
                } else if editor.canEdit {
                    SourceEditor($editor.text,
                                 language: CodeLanguage.detectLanguageFrom(url: URL(fileURLWithPath: path)),
                                 configuration: .init(appearance: .init(theme: theme,
                                     font: .monospacedSystemFont(ofSize: 12, weight: .regular), wrapLines: false)),
                                 state: $state)
                        .id(path)
                        .accessibilityLabel("Source editor")
                } else if editor.error == nil {
                    ProgressView("Opening file…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("File Can’t Be Edited", systemImage: "doc.badge.ellipsis",
                                           description: Text("Select another file, or view its Git diff."))
                }
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc.text",
                                       description: Text("Choose a file to edit its local working copy."))
                if let error = editor.error { Text(error).textSelection(.enabled).padding() }
            }
        }
        .onChange(of: editor.path) { _, _ in state = SourceEditorState() }
    }

    var theme: EditorTheme {
        // Semantic AppKit colors resolve with the current appearance, including increased contrast.
        let _ = colorScheme
        return EditorTheme(text: .init(color: .textColor), insertionPoint: .textColor,
            invisibles: .init(color: .tertiaryLabelColor),
            // CodeEdit’s minimap reads brightnessComponent, which requires an RGB color.
            background: NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) ?? .black,
            lineHighlight: .quaternaryLabelColor, selection: .selectedTextBackgroundColor,
            keywords: .init(color: .systemPurple), commands: .init(color: .systemBlue),
            types: .init(color: .systemTeal), attributes: .init(color: .systemBrown),
            variables: .init(color: .textColor), values: .init(color: .systemBlue),
            numbers: .init(color: .systemBlue), strings: .init(color: .systemRed),
            characters: .init(color: .systemRed), comments: .init(color: .secondaryLabelColor))
    }
}

private struct WorkingFileDiff: View {
    let repository: URL
    let path: String
    let staged: Bool
    let revision: Int
    @State private var files: [DiffFile] = []
    @State private var error: String?
    @State private var loading = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if loading { ProgressView("Reading diff…") }
            else if let error {
                ContentUnavailableView("Couldn’t Read Diff", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if files.isEmpty {
                ContentUnavailableView("No \(staged ? "Staged" : "Unstaged") Diff", systemImage: "checkmark",
                                       description: Text("Diffs compare saved tracked files. Save edits first; untracked files have no Git diff yet."))
            } else {
                ScrollView {
                    LazyVStack { ForEach(files) { DiffFileView(file: $0) } }.padding()
                }.diffConfiguration(.codeReview.with(theme: colorScheme == .dark ? .dark : .light))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(repository.path)\0\(path)\0\(staged)\0\(revision)") {
            loading = true
            error = nil
            do {
                let diff = try await Task.detached {
                    try Repository(name: repository.lastPathComponent, url: repository).fileDiff(path: path, staged: staged)
                }.value
                let parsed = try await UnifiedDiffParser().parse(diff)
                guard !Task.isCancelled else { return }
                files = parsed
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}
#endif
