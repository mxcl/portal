#if os(macOS)
import AppKit
import SwiftUI
import PortalCore
import PortalEngine

private struct PaletteModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var paletteModel: AppModel? {
        get { self[PaletteModelKey.self] }
        set { self[PaletteModelKey.self] = newValue }
    }
}

struct PaletteCommands: Commands {
    @FocusedValue(\.paletteModel) private var model
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Command Palette…") { model?.showPalette() }
                .keyboardShortcut("p")
                .disabled(model == nil)
        }
    }
}

struct PaletteTarget: Sendable {
    let project: String
    let source: ProjectSource
    let label: String
    let priority: Int
}

struct PaletteResult: Identifiable, Sendable {
    let project: String
    let target: PaletteTarget?
    let match: RepositorySearchMatch?
    let title: String
    let rank: Int
    var id: String { project + "\0" + (match?.reference?.fullName ?? "") + "\0" + (match?.commit.oid ?? "") }
    var symbol: String {
        guard let match else { return "folder" }
        guard let reference = match.reference else { return "number" }
        return reference.fullName.contains("/tags/") ? "tag" : "arrow.triangle.branch"
    }
}

@MainActor
final class PaletteSearch: ObservableObject {
    @Published private(set) var results: [PaletteResult] = []
    @Published private(set) var failures: [String] = []
    @Published private(set) var isLoading = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    // Git/SSH are blocking APIs. Bound them across query generations as well as sources.
    private nonisolated static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }

    func search(_ query: String, projects: [String], targets: [PaletteTarget], hosts: [SyncHost],
                read: @escaping @Sendable (PaletteTarget, String) throws -> [RepositorySearchMatch]) {
        stop()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = generation
        results = projects.compactMap { name in
            PaletteMatch.rank(name, query: query).map {
                PaletteResult(project: name, target: nil, match: nil, title: name, rank: $0)
            }
        }
        sort()
        failures = []
        guard !query.isEmpty else { return }
        isLoading = !targets.isEmpty
        task = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await withTaskGroup(of: (PaletteTarget, Result<[RepositorySearchMatch], Error>).self) { group in
                var pending = targets.makeIterator()
                func enqueue(_ target: PaletteTarget) {
                    group.addTask {
                        let result = await Self.read { try read(target, query) }
                        return (target, result)
                    }
                }
                for _ in 0..<4 { if let target = pending.next() { enqueue(target) } }
                for await (target, response) in group {
                    guard !Task.isCancelled, generation == self.generation else { group.cancelAll(); return }
                    switch response {
                    case .success(let matches):
                        for match in matches {
                            let title = match.reference?.displayName(hosts: hosts) ?? String(match.commit.oid.prefix(12))
                            let rank = match.reference.map {
                                PaletteMatch.rank($0.name, query: query) ?? 3
                            } ?? (match.commit.oid == query.lowercased() ? 0 : 1)
                            let result = PaletteResult(project: target.project, target: target, match: match, title: title, rank: rank)
                            if let index = self.results.firstIndex(where: { $0.id == result.id }) {
                                if target.priority < (self.results[index].target?.priority ?? Int.max) { self.results[index] = result }
                            } else { self.results.append(result) }
                        }
                        self.sort()
                    case .failure(let error):
                        self.failures.append("\(target.project) — \(target.label): \(error.localizedDescription)")
                    }
                    if let target = pending.next() { enqueue(target) }
                }
            }
            if generation == self.generation { self.isLoading = false }
        }
    }

    private func sort() {
        results.sort {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let lhs = $0.title.lowercased(), rhs = $1.title.lowercased()
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
    }

    private nonisolated static func read(_ body: @escaping @Sendable () throws -> [RepositorySearchMatch]) async
        -> Result<[RepositorySearchMatch], Error> {
        if Task.isCancelled { return .failure(CancellationError()) }
        let progress = Progress(totalUnitCount: 1)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.addOperation {
                    continuation.resume(returning: Result {
                        guard !progress.isCancelled else { throw CancellationError() }
                        return try body()
                    })
                }
            }
        } onCancel: { progress.cancel() }
    }
}

struct PaletteOverlay: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12).ignoresSafeArea()
                .onTapGesture { model.dismissPalette() }
            CommandPalette(model: model).padding(.top, 44)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CommandPalette: View {
    @ObservedObject var model: AppModel
    @StateObject private var search = PaletteSearch()
    @State private var query = ""
    @State private var selection: String?
    @State private var movedSelection = false

    private func refresh() {
        let configuration = model.configuration
        search.search(query, projects: model.paletteProjects, targets: model.paletteTargets,
                      hosts: configuration.hosts) { target, query in
            try AppModel.search(target, query: query, configuration: configuration)
        }
    }

    private func open() {
        guard let result = search.results.first(where: { $0.id == selection }) else { return }
        model.openPaletteResult(result)
    }

    private func move(_ delta: Int) {
        guard !search.results.isEmpty else { return }
        movedSelection = true
        let index = search.results.firstIndex(where: { $0.id == selection }) ?? 0
        selection = search.results[min(max(0, index + delta), search.results.count - 1)].id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PaletteSearchField(query: $query, move: move, open: open, dismiss: model.dismissPalette)
                    .frame(height: 28)
                if search.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Searching") }
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                List(selection: $selection) {
                    ForEach(search.results) { result in
                        HStack(spacing: 10) {
                            Image(systemName: result.symbol).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).lineLimit(1)
                                if let match = result.match {
                                    Text("\(result.project) · \(result.target?.label ?? "") · \(match.commit.subject)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3).contentShape(Rectangle())
                        .tag(result.id).id(result.id)
                        .onTapGesture { selection = result.id; open() }
                        .accessibilityElement(children: .combine)
                        .accessibilityAction { selection = result.id; open() }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, value in if let value { proxy.scrollTo(value) } }
                .overlay {
                    if search.results.isEmpty {
                        Text(search.isLoading ? "Searching…" : "No results")
                            .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
            }.frame(height: 300)
            Divider()
            HStack {
                if !search.failures.isEmpty {
                    Label("Some sources unavailable", systemImage: "exclamationmark.triangle")
                        .help(search.failures.joined(separator: "\n"))
                    Button("Retry", action: refresh).buttonStyle(.link)
                } else { Text("↑↓ Select    ↵ Open    Esc Close") }
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .shadow(radius: 20, y: 8)
        .onAppear(perform: refresh)
        .onDisappear { search.stop() }
        .onChange(of: query) { _, _ in movedSelection = false; selection = nil; refresh() }
        .onChange(of: search.results.map(\.id)) { _, ids in
            if !movedSelection || selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .onExitCommand { model.dismissPalette() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command Palette")
    }
}
/// Focus on attachment, before another key event can reach the underlying editor
/// or terminal. AppKit also owns marked-text handling and the accessible clear button.
private struct PaletteSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let open: () -> Void
    let dismiss: () -> Void

    final class Field: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.makeFirstResponder(self) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.placeholderString = "Search projects, branches, tags, or SHA"
        field.setAccessibilityLabel("Search projects, branches, tags, or SHA")
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != query { field.stringValue = query }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PaletteSearchField
        init(_ parent: PaletteSearchField) { self.parent = parent }
        @objc func changed(_ field: NSSearchField) {
            guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.query = field.stringValue
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { changed(field) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.open()
            case #selector(NSResponder.cancelOperation(_:)): parent.dismiss()
            default: return false
            }
            return true
        }
    }
}
#endif
