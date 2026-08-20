import AppKit
import Foundation

@MainActor
final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row {
        case header(String)
        case session(SessionPickerItem)
        case completion(CompletionSuggestion)
        case message(String)

        var isSelectable: Bool {
            switch self {
            case .session, .completion: true
            case .header, .message: false
            }
        }
    }

    var onRunCommand: ((String) -> Void)?
    var onOpenSession: ((SessionPickerCandidate) -> Void)?
    var onLaunchApplication: ((CompletionSuggestion) -> Void)?
    var onCancel: (() -> Void)?
    var onHeightChanged: ((CGFloat) -> Void)?

    private let input = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let completionEngine = PortalCompletionEngine()
    private let completionQueue = DispatchQueue(label: "dev.mxcl.portal.launcher-completion", qos: .userInitiated)
    private let sessionModel = SessionPickerModel()
    private var rows: [Row] = []
    private var completionSerial = 0

    override func loadView() {
        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        let content = NSView()
        glass.contentView = content
        view = glass

        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        input.placeholderString = "Run a command or open an app"
        input.focusRingType = .none
        input.isBordered = false
        input.drawsBackground = false
        input.setAccessibilityLabel("Portal command launcher")
        input.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("result"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelectedRow(_:))

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(input)
        content.addSubview(separator)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            input.topAnchor.constraint(equalTo: content.topAnchor),
            input.heightAnchor.constraint(equalToConstant: 56),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: input.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshSessions()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(input)
    }

    func reset() {
        completionSerial += 1
        input.stringValue = ""
        refreshSessions()
        view.window?.makeFirstResponder(input)
    }

    func suspend() {
        completionSerial += 1
        sessionModel.invalidate()
    }

    func showError(_ message: String) {
        rows = [.message(message)]
        reloadRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return 48 }
        if case .header = rows[row] { return 28 }
        return 52
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        case .message(let message):
            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        case .session(let item):
            return resultCell(
                title: item.title,
                detail: [item.subtitle, item.metadata].compactMap { $0 }.joined(separator: " · "),
                icon: Bundle.main.image(forResource: NSImage.Name("session-icon"))
            )
        case .completion(let suggestion):
            let icon = suggestion.kind == .application
                ? NSWorkspace.shared.icon(forFile: suggestion.source)
                : NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            return resultCell(
                title: suggestion.displayText,
                detail: suggestion.description ?? suggestion.source,
                icon: icon
            )
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = input.stringValue
        if query.isEmpty {
            refreshSessions()
        } else {
            refreshCompletions(query)
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
        case #selector(NSResponder.insertTab(_:)):
            acceptSelectedCompletion()
        case #selector(NSResponder.insertNewline(_:)):
            activateSelectionOrInput()
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?()
        default:
            return false
        }
        return true
    }

    @objc private func openSelectedRow(_ sender: Any?) {
        activateSelectionOrInput()
    }

    private func resultCell(title: String, detail: String, icon: NSImage?) -> NSTableCellView {
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = icon
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(labels)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 28),
            image.heightAnchor.constraint(equalToConstant: 28),
            labels.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func refreshSessions() {
        let hostname = Host.current().localizedName ?? "This Mac"
        sessionModel.refresh(
            initial: [],
            excluding: [],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            loadLocal: {
                try? PtySession.listSessions().map { session in
                    SessionPickerCandidate(
                        sessionRef: .local(session.sessionID),
                        hostTitle: hostname,
                        title: session.title,
                        cwd: session.cwd,
                        isClosed: false,
                        createdAt: session.createdAt,
                        commandCount: session.commandCount,
                        lastCommandAt: session.lastCommandAt,
                        runningCommand: session.runningCommand,
                        commandHistory: session.commandHistory,
                        action: .attach,
                        attachedClientCount: session.attachedClientCount
                    )
                }
            },
            loadRelay: { await Self.relayCandidates() },
            isAvailable: { _ in true },
            onUpdate: { [weak self] snapshot in
                guard let self, self.input.stringValue.isEmpty else { return }
                self.rows = snapshot.sections.flatMap { section in
                    [Row.header(section.title)] + section.items.map(Row.session)
                }
                if self.rows.isEmpty {
                    self.rows = [.message("No active sessions")]
                }
                self.reloadRows()
            }
        )
    }

    private func refreshCompletions(_ query: String) {
        completionSerial += 1
        let serial = completionSerial
        let cancellation = CompletionCancellation()
        let request = CompletionRequest(
            input: query,
            cursorOffset: query.utf16.count,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path,
            shellPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            environment: ProcessInfo.processInfo.environment,
            location: .local,
            limit: 64,
            cancellation: cancellation,
            relayProvider: nil,
            includesHistory: query.utf16.count >= 2,
            historyOnly: false
        )
        completionQueue.async { [weak self] in
            guard let self else { return }
            let result = self.completionEngine.completions(for: request)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      serial == self.completionSerial,
                      self.input.stringValue == query
                else { return }
                self.rows = result.suggestions.map(Row.completion)
                if self.rows.isEmpty {
                    self.rows = [.message("Return to run “\(query)”")]
                }
                self.reloadRows(selectsFirst: true)
            }
        }
    }

    private func reloadRows(selectsFirst: Bool = false) {
        table.reloadData()
        if selectsFirst, let row = rows.firstIndex(where: \.isSelectable) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let rowsHeight = rows.prefix(8).enumerated().reduce(CGFloat.zero) { height, pair in
            height + tableView(table, heightOfRow: pair.offset)
        }
        onHeightChanged?(min(56 + rowsHeight, 56 + 8 * 52))
    }

    private func moveSelection(_ offset: Int) {
        let selectable = rows.indices.filter { rows[$0].isSelectable }
        guard !selectable.isEmpty else { return }
        let current = table.selectedRow
        let index = selectable.firstIndex(of: current) ?? (offset > 0 ? -1 : 0)
        let next = (index + offset + selectable.count) % selectable.count
        table.selectRowIndexes(IndexSet(integer: selectable[next]), byExtendingSelection: false)
        table.scrollRowToVisible(selectable[next])
    }

    private func acceptSelectedCompletion() {
        guard rows.indices.contains(table.selectedRow),
              case .completion(let suggestion) = rows[table.selectedRow]
        else { return }
        input.stringValue = suggestion.insertText
        refreshCompletions(input.stringValue)
    }

    private func activateSelectionOrInput() {
        if rows.indices.contains(table.selectedRow) {
            switch rows[table.selectedRow] {
            case .session(let item):
                onOpenSession?(item.candidate)
                return
            case .completion(let suggestion):
                if suggestion.kind == .application {
                    input.stringValue = suggestion.insertText
                    onLaunchApplication?(suggestion)
                } else {
                    onRunCommand?(suggestion.insertText.trimmingCharacters(in: .whitespaces))
                }
                return
            case .header, .message:
                break
            }
        }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { onRunCommand?(command) }
    }

    private static func relayCandidates() async -> [SessionPickerCandidate]? {
        guard let endpoint = try? MacRemoteAccessController.relayEndpoint(),
              let key = try? ICloudKeychainRootKey().loadOrCreate(),
              let client = try? RelayCatalogClient(endpoint: endpoint, rootKeyData: key),
              let data = try? await client.load(),
              let catalog = try? JSONDecoder().decode(RemoteCatalog.self, from: data)
        else { return nil }

        let now = Date()
        let localMacID = MacRemoteAccessController.macID()
        return catalog.macs
            .filter { $0.id != localMacID && $0.online && now.timeIntervalSince($0.lastSeen) < 10 }
            .flatMap { mac in
                mac.sessions.map { session in
                    SessionPickerCandidate(
                        sessionRef: SessionRef(
                            location: .relayMac(mac.id),
                            sessionID: session.sessionID,
                            hostName: mac.name
                        ),
                        hostTitle: mac.name,
                        title: session.title,
                        cwd: session.cwd,
                        isClosed: false,
                        createdAt: session.createdAt,
                        commandCount: session.commandCount,
                        lastCommandAt: session.lastCommandAt,
                        runningCommand: session.runningCommand,
                        commandHistory: [],
                        action: .attach,
                        attachedClientCount: session.attachedClientCount
                    )
                }
            }
    }
}
