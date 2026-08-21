import AppKit
import Foundation

private final class LauncherSessionDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class LauncherViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private enum Row {
        case completion(CompletionSuggestion)
        case message(String)

        var isSelectable: Bool {
            switch self {
            case .completion: true
            case .message: false
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
    private let sessionScroll = NSScrollView()
    private let sessionDocument = LauncherSessionDocument()
    private let sessionStack = NSStackView()
    private let completionEngine = PortalCompletionEngine()
    private let completionQueue = DispatchQueue(label: "dev.mxcl.portal.launcher-completion", qos: .userInitiated)
    private let sessionModel = SessionPickerModel()
    private var rows: [Row] = []
    private var sessionButtons: [SessionCandidateButton] = []
    private var sessionRowStarts: [Int] = []
    private var sessionCandidates: [SessionRef: SessionPickerCandidate] = [:]
    private var renderedSnapshot: SessionPickerSnapshot?
    private var selectedSessionRef: SessionRef?
    private var sessionMouseDownMonitor: Any?
    private var completionSerial = 0

    static func keyboardSelectionSelfTest() -> Bool {
        let rows = [0, 4, 5, 9]
        return sessionSelectionDestination(current: nil, delta: -4, rowStarts: rows, count: 13) == 9
            && sessionSelectionDestination(current: 8, delta: -1, rowStarts: rows, count: 13) == 7
            && sessionSelectionDestination(current: 5, delta: -1, rowStarts: rows, count: 13) == nil
            && sessionSelectionDestination(current: 5, delta: 1, rowStarts: rows, count: 13) == 6
            && sessionSelectionDestination(current: 8, delta: 1, rowStarts: rows, count: 13) == nil
            && sessionSelectionDestination(current: 11, delta: -4, rowStarts: rows, count: 13) == 7
            && sessionSelectionDestination(current: 8, delta: -4, rowStarts: rows, count: 13) == 4
            && sessionSelectionDestination(current: 4, delta: 4, rowStarts: rows, count: 13) == 5
            && sessionSelectionDestination(current: 7, delta: 4, rowStarts: rows, count: 13) == 11
    }

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

        sessionDocument.translatesAutoresizingMaskIntoConstraints = false
        sessionStack.orientation = .vertical
        sessionStack.alignment = .leading
        sessionStack.spacing = 10
        sessionStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        sessionStack.translatesAutoresizingMaskIntoConstraints = false
        sessionDocument.addSubview(sessionStack)
        NSLayoutConstraint.activate([
            sessionStack.leadingAnchor.constraint(equalTo: sessionDocument.leadingAnchor),
            sessionStack.trailingAnchor.constraint(equalTo: sessionDocument.trailingAnchor),
            sessionStack.topAnchor.constraint(equalTo: sessionDocument.topAnchor),
            sessionStack.bottomAnchor.constraint(equalTo: sessionDocument.bottomAnchor),
        ])

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.isHidden = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        sessionScroll.documentView = sessionDocument
        sessionScroll.drawsBackground = false
        sessionScroll.hasVerticalScroller = true
        sessionScroll.autohidesScrollers = true
        sessionScroll.verticalScrollElasticity = .none
        sessionScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sessionDocument.topAnchor.constraint(equalTo: sessionScroll.contentView.topAnchor),
            sessionDocument.widthAnchor.constraint(equalTo: sessionScroll.contentView.widthAnchor),
        ])

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(input)
        content.addSubview(separator)
        content.addSubview(scroll)
        content.addSubview(sessionScroll)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            input.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -28),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -56),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            sessionScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sessionScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            sessionScroll.topAnchor.constraint(equalTo: content.topAnchor),
            sessionScroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sessionMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  event.window === self.view.window,
                  !self.sessionScroll.isHidden,
                  let button = self.sessionButtons.first(where: {
                      $0.bounds.contains($0.convert(event.locationInWindow, from: nil))
                  })
            else { return event }
            self.openSessionCard(button)
            return nil
        }
        refreshSessions()
    }

    deinit {
        if let sessionMouseDownMonitor {
            NSEvent.removeMonitor(sessionMouseDownMonitor)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(input)
    }

    func reset() {
        completionSerial += 1
        selectedSessionRef = nil
        sessionButtons.forEach { $0.isKeyboardSelected = false }
        input.stringValue = ""
        refreshSessions()
        view.window?.makeFirstResponder(input)
    }

    func suspend() {
        completionSerial += 1
        sessionModel.invalidate()
    }

    func showError(_ message: String) {
        scroll.isHidden = false
        sessionScroll.isHidden = true
        rows = [.message(message)]
        reloadRows()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 52
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .message(let message):
            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
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
            input.stringValue.isEmpty ? moveSessionSelection(columns: 4) : moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            input.stringValue.isEmpty ? moveSessionSelection(columns: -4) : moveSelection(-1)
        case #selector(NSResponder.moveLeft(_:)) where input.stringValue.isEmpty:
            moveSessionSelection(columns: -1)
        case #selector(NSResponder.moveRight(_:)) where input.stringValue.isEmpty:
            moveSessionSelection(columns: 1)
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
        scroll.isHidden = true
        sessionScroll.isHidden = false
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
                self.renderSessions(snapshot)
            }
        )
    }

    private func renderSessions(_ snapshot: SessionPickerSnapshot) {
        guard snapshot != renderedSnapshot else { return }
        renderedSnapshot = snapshot
        sessionCandidates = Dictionary(uniqueKeysWithValues: snapshot.sections.flatMap { section in
            section.items.map { ($0.candidate.sessionRef, $0.candidate) }
        })
        sessionButtons.removeAll()
        sessionRowStarts.removeAll()
        for view in sessionStack.arrangedSubviews {
            sessionStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for section in snapshot.sections {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            sessionStack.addArrangedSubview(header)

            if section.items.isEmpty {
                let empty = NSTextField(labelWithString: "No active sessions")
                empty.font = .systemFont(ofSize: 12, weight: .regular)
                empty.textColor = .tertiaryLabelColor
                empty.alignment = .center
                empty.heightAnchor.constraint(equalToConstant: 82).isActive = true
                sessionStack.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
                continue
            }

            for start in stride(from: 0, to: section.items.count, by: 4) {
                sessionRowStarts.append(sessionButtons.count)
                let buttons = section.items[start..<min(start + 4, section.items.count)].map { item in
                    let button = SessionCandidateButton(
                        sessionRef: item.candidate.sessionRef,
                        title: item.title,
                        subtitle: item.subtitle,
                        metadata: item.metadata
                    )
                    button.target = self
                    button.action = #selector(openSessionCard(_:))
                    button.isKeyboardSelected = item.candidate.sessionRef == selectedSessionRef
                    sessionButtons.append(button)
                    return button
                }
                let row = SessionCandidateRowView(buttons: buttons)
                sessionStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: sessionStack.widthAnchor).isActive = true
            }
        }

        if let selectedSessionRef, !sessionCandidates.keys.contains(selectedSessionRef) {
            self.selectedSessionRef = nil
        }
        sessionDocument.layoutSubtreeIfNeeded()
        onHeightChanged?(56 + sessionStack.fittingSize.height)
    }

    @objc private func openSessionCard(_ sender: SessionCandidateButton) {
        guard let candidate = sessionCandidates[sender.sessionRef] else { return }
        selectedSessionRef = sender.sessionRef
        onOpenSession?(candidate)
    }

    private func refreshCompletions(_ query: String) {
        scroll.isHidden = false
        sessionScroll.isHidden = true
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

    private func moveSessionSelection(columns delta: Int) {
        guard !sessionButtons.isEmpty else { return }
        let current = selectedSessionRef.flatMap { selected in
            sessionButtons.firstIndex { $0.sessionRef == selected }
        }
        guard let destination = Self.sessionSelectionDestination(
            current: current,
            delta: delta,
            rowStarts: sessionRowStarts,
            count: sessionButtons.count
        ) else { return }
        sessionButtons.forEach { $0.isKeyboardSelected = false }
        let button = sessionButtons[destination]
        button.isKeyboardSelected = true
        selectedSessionRef = button.sessionRef
        button.scrollToVisible(button.bounds)
    }

    private static func sessionSelectionDestination(
        current: Int?,
        delta: Int,
        rowStarts: [Int],
        count: Int
    ) -> Int? {
        guard count > 0, !rowStarts.isEmpty else { return nil }
        guard let current else {
            return delta == -1 ? count - 1 : delta < 0 ? rowStarts.last : 0
        }
        guard let row = rowStarts.lastIndex(where: { $0 <= current }) else { return nil }
        let rowEnd = (rowStarts.indices.contains(row + 1) ? rowStarts[row + 1] : count) - 1
        if delta == -1 { return current > rowStarts[row] ? current - 1 : nil }
        if delta == 1 { return current < rowEnd ? current + 1 : nil }

        let targetRow = row + (delta < 0 ? -1 : 1)
        guard rowStarts.indices.contains(targetRow) else { return nil }
        let targetEnd = (rowStarts.indices.contains(targetRow + 1) ? rowStarts[targetRow + 1] : count) - 1
        return min(rowStarts[targetRow] + current - rowStarts[row], targetEnd)
    }

    private func acceptSelectedCompletion() {
        guard rows.indices.contains(table.selectedRow),
              case .completion(let suggestion) = rows[table.selectedRow]
        else { return }
        input.stringValue = suggestion.insertText
        refreshCompletions(input.stringValue)
    }

    private func activateSelectionOrInput() {
        if input.stringValue.isEmpty,
           let selectedSessionRef,
           let candidate = sessionCandidates[selectedSessionRef] {
            onOpenSession?(candidate)
            return
        }
        if !input.stringValue.isEmpty, rows.indices.contains(table.selectedRow) {
            switch rows[table.selectedRow] {
            case .completion(let suggestion):
                if suggestion.kind == .application {
                    input.stringValue = suggestion.insertText
                    onLaunchApplication?(suggestion)
                } else {
                    onRunCommand?(suggestion.insertText.trimmingCharacters(in: .whitespaces))
                }
                return
            case .message:
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
