import AppKit
import Darwin
import Foundation
import JavaScriptCore

struct CompletionRequest {
    let input: String
    let cursorOffset: Int
    let cwd: String
    let shellPath: String
    let environment: [String: String]
    let location: SessionLocation
    let limit: Int
    let cancellation: CompletionCancellation
    let relayProvider: RelayCompletionProvider?
    let includesHistory: Bool
}

struct CompletionResult {
    let replacementRange: NSRange
    let suggestions: [CompletionSuggestion]
    let commonPrefix: String?
    let diagnostics: [String]
}

struct CompletionSuggestion {
    enum Kind {
        case history
        case command
        case subcommand
        case option
        case argument
        case file
        case folder
    }

    let displayText: String
    let insertText: String
    let description: String?
    let kind: Kind
    let priority: Int
    let source: String
    let replacementRange: NSRange?

    init(
        displayText: String,
        insertText: String,
        description: String?,
        kind: Kind,
        priority: Int,
        source: String,
        replacementRange: NSRange? = nil
    ) {
        self.displayText = displayText
        self.insertText = insertText
        self.description = description
        self.kind = kind
        self.priority = priority
        self.source = source
        self.replacementRange = replacementRange
    }
}

private struct BridgePathCompletionRequest: Encodable {
    let cwd: String
    let prefix: String
    let foldersOnly: Bool
}

private struct BridgeCommandCompletionRequest: Encodable {
    let prefix: String
}

private struct BridgeGeneratorRequest: Encodable {
    struct EnvironmentPair: Encodable {
        let key: String
        let value: String
    }

    let commandLine: String
    let cwd: String
    let environment: [EnvironmentPair]
    let timeoutMs: Int
    let outputLimit: Int
}

private struct BridgeHistoryQueryRequest: Encodable {
    let cwd: String
    let prefix: String
    let limit: Int
}

private struct BridgeHistoryRecordRequest: Encodable {
    let command: String
    let cwd: String
}

private struct BridgeCompletionResponse: Decodable {
    let suggestions: [BridgeCompletionSuggestion]
}

private struct BridgeCompletionSuggestion: Decodable {
    let displayText: String
    let insertText: String
    let description: String?
    let kind: String
    let priority: Int
    let source: String
    let isExecutable: Bool
}

private struct BridgeGeneratorOutput: Decodable {
    let stdout: String
    let stderr: String
    let status: Int32
}

final class CompletionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private final class RelayCompletionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Data?

    func store(_ result: Data?) {
        lock.withLock { self.result = result }
    }

    func load() -> Data? {
        lock.withLock { result }
    }
}

final class RelayCompletionProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var client: RemoteTerminalSessionClient?
    private var generation = UUID().uuidString
    private var revision = 0
    private var completionSupported = false
    private var historySupported = false
    private var commandData: Data?
    private var commandTask: Task<Data?, Never>?

    var cacheIdentity: String {
        lock.withLock { "\(generation):\(revision)" }
    }

    func connect(_ client: RemoteTerminalSessionClient) {
        lock.withLock {
            commandTask?.cancel()
            self.client = client
            generation = UUID().uuidString
            revision = 0
            completionSupported = false
            historySupported = false
            commandData = nil
            commandTask = nil
        }
    }

    func enable(_ capabilities: Set<String>) {
        let state: (RemoteTerminalSessionClient, String)? = lock.withLock {
            historySupported = capabilities.contains(RemoteCapabilities.relayHistory)
            guard capabilities.contains(RemoteCapabilities.relayCompletion),
                  !completionSupported,
                  let client
            else { return nil }
            completionSupported = true
            return (client, generation)
        }
        guard let (client, generation) = state else { return }
        guard let input = try? JSONEncoder().encode(
            BridgeCommandCompletionRequest(prefix: "")
        ) else { return }
        let task = Task {
            try? await client.complete(
                operation: .completeCommands,
                payload: input,
                timeout: 2
            )
        }
        lock.withLock {
            guard self.generation == generation else {
                task.cancel()
                return
            }
            commandTask = task
        }
        Task { [weak self] in
            guard let data = await task.value else { return }
            self?.storeCommands(data, generation: generation)
        }
    }

    func disconnect() {
        lock.withLock {
            commandTask?.cancel()
            client = nil
            generation = UUID().uuidString
            revision = 0
            completionSupported = false
            historySupported = false
            commandData = nil
            commandTask = nil
        }
    }

    func run(
        operation: RemoteCompletionOperation,
        input: Data,
        timeout: TimeInterval,
        cancellation: CompletionCancellation
    ) -> Data? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !cancellation.isCancelled else { return nil }

        if operation == .completeCommands {
            let cached: Data? = lock.withLock { commandData }
            if let cached { return cached }
            let prefetched: Task<Data?, Never>? = lock.withLock { commandTask }
            if let prefetched {
                return wait(
                    for: prefetched,
                    cancellation: cancellation,
                    cancelsTask: false
                )
            }
        }

        let client: RemoteTerminalSessionClient? = lock.withLock {
            let supported = switch operation.requiredCapability {
            case RemoteCapabilities.relayCompletion: completionSupported
            case RemoteCapabilities.relayHistory: historySupported
            default: false
            }
            return supported ? self.client : nil
        }
        guard let client else { return nil }
        let task = Task {
            try? await client.complete(
                operation: operation,
                payload: input,
                timeout: timeout
            )
        }
        let result = wait(for: task, cancellation: cancellation, cancelsTask: true)
        if operation == .completeCommands, let result {
            let currentGeneration = lock.withLock { generation }
            storeCommands(result, generation: currentGeneration)
        }
        return result
    }

    private func wait(
        for task: Task<Data?, Never>,
        cancellation: CompletionCancellation,
        cancelsTask: Bool
    ) -> Data? {
        let result = RelayCompletionResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let waiter = Task {
            result.store(await task.value)
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.01) == .timedOut {
            if cancellation.isCancelled {
                waiter.cancel()
                if cancelsTask { task.cancel() }
                return nil
            }
        }
        return result.load()
    }

    private func storeCommands(_ data: Data, generation: String) {
        lock.withLock {
            guard self.generation == generation else { return }
            commandData = data
            commandTask = nil
            revision += 1
        }
    }
}

final class CompletionPopupController: NSObject, NSPopoverDelegate {
    private static let popupWidth: CGFloat = 360
    private static let maxPopupHeight: CGFloat = 232
    private static let minPopupHeight: CGFloat = 44
    private static let popupMargin: CGFloat = 12

    private struct PopupPlacement {
        let rect: NSRect
        let edge: NSRectEdge
        let height: CGFloat
    }

    private let popover = NSPopover()
    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: popupWidth, height: 44))
    private let listView = CompletionListView(frame: .zero)
    private var suggestions: [CompletionSuggestion] = []
    private var selectedIndex = 0
    private var showsSelection = false
    private weak var presentationView: NSView?
    private var presentationEdge: NSRectEdge?
    private var placementSerial = 0
    private var suppressCloseNotification = false
    private var currentContentSize = NSSize(width: popupWidth, height: 44)
    private var currentDocumentHeight: CGFloat = 0

    var isShown: Bool { popover.isShown }
    var onExternalDismiss: (() -> Void)?
    var onSelectionChanged: ((CompletionSuggestion) -> Void)?
    var onAcceptSuggestion: ((CompletionSuggestion) -> Void)?
    var selectedSuggestion: CompletionSuggestion? {
        guard suggestions.indices.contains(selectedIndex) else { return nil }
        return suggestions[selectedIndex]
    }

    override init() {
        super.init()

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = listView

        let viewController = NSViewController()
        viewController.view = scrollView
        viewController.preferredContentSize = scrollView.frame.size

        popover.contentViewController = viewController
        popover.behavior = .semitransient
        popover.animates = false
        popover.delegate = self

        listView.onHoverRow = { [weak self] index in
            self?.selectMouseHoveredRow(index)
        }
        listView.onClickRow = { [weak self] index in
            self?.acceptMouseClickedRow(index)
        }
    }

    func show(
        suggestions: [CompletionSuggestion],
        relativeTo rect: NSRect,
        of view: NSView,
        resetSelection: Bool = true
    ) {
        self.suggestions = suggestions
        selectedIndex = suggestions.isEmpty ? 0 : (resetSelection ? 0 : min(selectedIndex, suggestions.count - 1))
        self.showsSelection = !suggestions.isEmpty

        let contentHeight = CompletionListView.contentHeight(forRowCount: suggestions.count)
        let placement = popupPlacement(for: rect, of: view, contentHeight: contentHeight)
        let shouldFlashScrollers = contentHeight > placement.height
        let size = NSSize(width: Self.popupWidth, height: placement.height)
        let geometryChanged = currentContentSize != size ||
            currentDocumentHeight != contentHeight ||
            scrollView.hasVerticalScroller != shouldFlashScrollers
        let needsGeometryUpdate = !popover.isShown || geometryChanged

        if needsGeometryUpdate {
            currentContentSize = size
            currentDocumentHeight = contentHeight
            scrollView.hasVerticalScroller = shouldFlashScrollers
            listView.frame = NSRect(x: 0, y: 0, width: Self.popupWidth, height: contentHeight)
        }
        listView.update(suggestions: suggestions, selectedIndex: self.showsSelection ? selectedIndex : nil)
        if needsGeometryUpdate {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
        }

        placementSerial += 1
        let serial = placementSerial

        if popover.isShown {
            if presentationView !== view || presentationEdge != placement.edge {
                performInternalRepositionClose()
                present(relativeTo: placement.rect, of: view, preferredEdge: placement.edge)
            } else {
                popover.positioningRect = placement.rect
                reapplyPositioningRect(placement.rect, serial: serial)
            }
            return
        }

        present(relativeTo: placement.rect, of: view, preferredEdge: placement.edge)
        reapplyPositioningRect(placement.rect, serial: serial)
        if shouldFlashScrollers {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.scrollView.flashScrollers()
            }
        }
    }

    func reposition(relativeTo rect: NSRect, of view: NSView) {
        guard popover.isShown else { return }

        let placement = popupPlacement(for: rect, of: view, contentHeight: currentDocumentHeight)
        let size = NSSize(width: Self.popupWidth, height: placement.height)
        if currentContentSize != size {
            currentContentSize = size
            scrollView.hasVerticalScroller = currentDocumentHeight > placement.height
            listView.frame = NSRect(x: 0, y: 0, width: Self.popupWidth, height: currentDocumentHeight)
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
        }
        placementSerial += 1
        let serial = placementSerial

        if presentationView !== view || presentationEdge != placement.edge {
            performInternalRepositionClose()
            present(relativeTo: placement.rect, of: view, preferredEdge: placement.edge)
        } else {
            popover.positioningRect = placement.rect
            reapplyPositioningRect(placement.rect, serial: serial)
        }
    }

    private func performInternalRepositionClose() {
        suppressCloseNotification = true
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            self?.suppressCloseNotification = false
        }
    }

    private func present(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        presentationView = view
        presentationEdge = preferredEdge
        popover.show(
            relativeTo: rect,
            of: view,
            preferredEdge: preferredEdge
        )
    }

    private func reapplyPositioningRect(_ rect: NSRect, serial: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.popover.isShown,
                  self.placementSerial == serial
            else {
                return
            }
            self.popover.positioningRect = rect
        }
    }

    private func popupPlacement(for rect: NSRect, of view: NSView, contentHeight: CGFloat) -> PopupPlacement {
        let fallbackHeight = min(Self.maxPopupHeight, contentHeight)
        guard let window = view.window else {
            return PopupPlacement(rect: positioningRect(for: rect), edge: .maxY, height: fallbackHeight)
        }

        let windowRect = view.convert(rect, to: nil)
        let screenRect = window.convertToScreen(windowRect)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let halfWindowHeight = max(Self.minPopupHeight, window.frame.height / 2)
        let availableBelow = screenRect.minY - visibleFrame.minY
        let availableAbove = visibleFrame.maxY - screenRect.maxY
        let availableRight = visibleFrame.maxX - screenRect.maxX

        if availableRight >= Self.popupWidth + Self.popupMargin {
            let down = min(halfWindowHeight, max(0, availableBelow - Self.popupMargin))
            let up = max(0, window.frame.maxY - screenRect.maxY - Self.popupMargin)
            let height = min(contentHeight, max(Self.minPopupHeight, down + up))
            return PopupPlacement(rect: positioningRect(for: rect), edge: .maxX, height: height)
        }

        let belowHeight = min(contentHeight, halfWindowHeight, max(Self.minPopupHeight, availableBelow - Self.popupMargin))
        if availableBelow >= Self.minPopupHeight + Self.popupMargin {
            return PopupPlacement(rect: positioningRect(for: rect), edge: .maxY, height: belowHeight)
        }

        let aboveHeight = min(contentHeight, halfWindowHeight, max(Self.minPopupHeight, availableAbove - Self.popupMargin))
        if availableAbove >= Self.minPopupHeight + Self.popupMargin {
            return PopupPlacement(rect: positioningRect(for: rect), edge: .minY, height: aboveHeight)
        }
        return PopupPlacement(
            rect: positioningRect(for: rect),
            edge: availableAbove > availableBelow ? .minY : .maxY,
            height: min(contentHeight, halfWindowHeight)
        )
    }

    private func positioningRect(for rect: NSRect) -> NSRect {
        return NSRect(
            x: rect.minX,
            y: rect.minY,
            width: max(1, rect.width),
            height: max(1, rect.height)
        )
    }

    func dismiss() {
        suggestions.removeAll()
        selectedIndex = 0
        showsSelection = false
        presentationView = nil
        presentationEdge = nil
        placementSerial += 1
        listView.update(suggestions: [], selectedIndex: nil)
        suppressCloseNotification = true
        popover.performClose(nil)
        DispatchQueue.main.async { [weak self] in
            self?.suppressCloseNotification = false
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !suppressCloseNotification else { return }
        suggestions.removeAll()
        selectedIndex = 0
        showsSelection = false
        presentationView = nil
        presentationEdge = nil
        placementSerial += 1
        listView.update(suggestions: [], selectedIndex: nil)
        onExternalDismiss?()
    }

    @discardableResult
    func selectNext() -> CompletionSuggestion? {
        guard !suggestions.isEmpty else { return nil }
        showsSelection = true
        selectedIndex = (selectedIndex + 1) % suggestions.count
        listView.update(suggestions: suggestions, selectedIndex: selectedIndex)
        scrollRowToVisible(selectedIndex)
        return selectedSuggestion
    }

    @discardableResult
    func selectPrevious() -> CompletionSuggestion? {
        guard !suggestions.isEmpty else { return nil }
        showsSelection = true
        selectedIndex = (selectedIndex + suggestions.count - 1) % suggestions.count
        listView.update(suggestions: suggestions, selectedIndex: selectedIndex)
        scrollRowToVisible(selectedIndex)
        return selectedSuggestion
    }

    private func scrollRowToVisible(_ row: Int) {
        let rowRect = listView.rowRect(for: row)
        let visibleRect = scrollView.contentView.bounds

        let targetY: CGFloat
        if rowRect.minY < visibleRect.minY {
            targetY = rowRect.minY
        } else if rowRect.maxY > visibleRect.maxY {
            targetY = rowRect.maxY - visibleRect.height
        } else {
            return
        }

        let maxY = max(0, listView.bounds.height - visibleRect.height)
        let clampedY = min(max(0, targetY), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: visibleRect.minX, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func selectMouseHoveredRow(_ row: Int) {
        guard suggestions.indices.contains(row) else { return }
        showsSelection = true
        guard selectedIndex != row || listView.selectedIndex != row else { return }

        selectedIndex = row
        listView.update(suggestions: suggestions, selectedIndex: selectedIndex)
        onSelectionChanged?(suggestions[row])
    }

    private func acceptMouseClickedRow(_ row: Int) {
        guard suggestions.indices.contains(row) else { return }
        showsSelection = true
        selectedIndex = row
        listView.update(suggestions: suggestions, selectedIndex: selectedIndex)
        onAcceptSuggestion?(suggestions[row])
    }
}

private final class CompletionListView: NSView {
    static let rowHeight: CGFloat = 36
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 8
    private static let rowContentPadding: CGFloat = 10

    private var suggestions: [CompletionSuggestion] = []
    fileprivate private(set) var selectedIndex: Int?
    var onHoverRow: ((Int) -> Void)?
    var onClickRow: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    static func contentHeight(forRowCount rowCount: Int) -> CGFloat {
        max(rowHeight, CGFloat(rowCount) * rowHeight) + verticalPadding * 2
    }

    func update(suggestions: [CompletionSuggestion], selectedIndex: Int?) {
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
        needsDisplay = true
    }

    func rowRect(for row: Int) -> NSRect {
        NSRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding + CGFloat(row) * Self.rowHeight,
            width: max(0, bounds.width - Self.horizontalPadding * 2),
            height: Self.rowHeight
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        guard let row = rowIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onHoverRow?(row)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let row = rowIndex(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onClickRow?(row)
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        guard point.y >= Self.verticalPadding else { return nil }
        let row = Int((point.y - Self.verticalPadding) / Self.rowHeight)
        guard suggestions.indices.contains(row),
              rowRect(for: row).contains(point)
        else {
            return nil
        }
        return row
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for (index, suggestion) in suggestions.enumerated() {
            let rowRect = rowRect(for: index)
            guard dirtyRect.intersects(rowRect) else { continue }

            let isSelected = selectedIndex.map { $0 == index } ?? false
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(
                    roundedRect: rowRect.insetBy(dx: 0, dy: 2),
                    xRadius: 8,
                    yRadius: 8
                ).fill()
            }

            draw(suggestion: suggestion, in: rowRect, isSelected: isSelected)
        }
    }

    private func draw(suggestion: CompletionSuggestion, in rowRect: NSRect, isSelected: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let primaryColor = isSelected ? NSColor.white : NSColor.labelColor
        let secondaryColor = isSelected ? NSColor.white.withAlphaComponent(0.78) : NSColor.secondaryLabelColor
        let tertiaryColor = isSelected ? NSColor.white.withAlphaComponent(0.70) : NSColor.tertiaryLabelColor
        let detail = suggestion.description ?? (suggestion.isFilesystemResult ? "" : suggestion.source)
        let kind = suggestion.isFilesystemResult ? "" : suggestion.kind.label

        let contentRect = rowRect.insetBy(dx: Self.rowContentPadding, dy: 0)
        let kindWidth: CGFloat = kind.isEmpty ? 0 : 64
        let kindRect = NSRect(
            x: contentRect.maxX - kindWidth,
            y: rowRect.minY + 10,
            width: kindWidth,
            height: 16
        )
        let nameMaxX = kind.isEmpty ? contentRect.maxX : kindRect.minX - 8
        let nameRect = NSRect(
            x: contentRect.minX,
            y: rowRect.minY + (detail.isEmpty ? 10 : 5),
            width: max(20, nameMaxX - contentRect.minX),
            height: 17
        )

        (suggestion.displayText as NSString).draw(
            in: nameRect,
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: primaryColor,
                .paragraphStyle: paragraph
            ]
        )

        if !detail.isEmpty {
            let detailRect = NSRect(
                x: contentRect.minX,
                y: rowRect.minY + 20,
                width: contentRect.width,
                height: 13
            )
            (detail as NSString).draw(
                in: detailRect,
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: secondaryColor,
                    .paragraphStyle: paragraph
                ]
            )
        }

        if !kind.isEmpty {
            let kindParagraph = NSMutableParagraphStyle()
            kindParagraph.alignment = .right
            kindParagraph.lineBreakMode = .byTruncatingTail
            (kind as NSString).draw(
                in: kindRect,
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: tertiaryColor,
                    .paragraphStyle: kindParagraph
                ]
            )
        }
    }
}

private extension CompletionSuggestion.Kind {
    var label: String {
        switch self {
        case .history: return "history"
        case .command: return "cmd"
        case .subcommand: return "subcmd"
        case .option: return "option"
        case .argument: return "arg"
        case .file: return "file"
        case .folder: return "folder"
        }
    }
}

private extension CompletionSuggestion {
    var isFilesystemResult: Bool {
        kind == .file || kind == .folder
    }
}

private final class CommandDescriptionStore {
    static let shared = CommandDescriptionStore()

    private let descriptions: [String: String]

    private init() {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("completions", isDirectory: true)
            .appendingPathComponent("command-descriptions.json", isDirectory: false),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            descriptions = [:]
            return
        }
        descriptions = decoded
    }

    func description(for command: String) -> String? {
        descriptions[command]
    }
}

final class VaulttyCompletionEngine {
    private static let maxPathSuggestionCandidates = 512
    private static let maxGeneratorSuggestionCandidates = 512
    private static let defaultGeneratorTimeout: TimeInterval = 10
    private static let maxGeneratorTimeout: TimeInterval = 15

    private let specLoader = FigSpecLoader()
    private let commandDescriptions = CommandDescriptionStore.shared
    private let fileManager = FileManager.default
    private var commandCache: [String: [CompletionSuggestion]] = [:]

    func completions(for request: CompletionRequest) -> CompletionResult {
        let standard = standardCompletions(for: request)
        guard request.includesHistory,
              request.cursorOffset == (request.input as NSString).length
        else {
            return standard
        }

        let history = historySuggestions(for: request)
        guard !history.isEmpty else { return standard }
        let exact = history.filter { $0.priority == 100 }
        let elsewhere = history.filter { $0.priority != 100 }
        var seen = Set<String>()
        let suggestions = (exact + standard.suggestions + elsewhere)
            .filter { seen.insert($0.insertText).inserted }
            .limited(to: request.limit)
        return CompletionResult(
            replacementRange: standard.replacementRange,
            suggestions: suggestions,
            commonPrefix: nil,
            diagnostics: standard.diagnostics
        )
    }

    func recordSuccessfulCommand(
        _ command: String,
        cwd: String,
        location: SessionLocation,
        relayProvider: RelayCompletionProvider?
    ) {
        guard let input = try? JSONEncoder().encode(
            BridgeHistoryRecordRequest(command: command, cwd: cwd)
        ) else { return }
        _ = runHostBridge(
            operation: .recordHistory,
            input: input,
            location: location,
            relayProvider: relayProvider,
            timeout: 2,
            cancellation: CompletionCancellation()
        )
    }

    @discardableResult
    func clearHistory(
        location: SessionLocation,
        relayProvider: RelayCompletionProvider?
    ) -> Bool {
        guard let input = try? JSONEncoder().encode([String: String]()) else { return false }
        return runHostBridge(
            operation: .clearHistory,
            input: input,
            location: location,
            relayProvider: relayProvider,
            timeout: 2,
            cancellation: CompletionCancellation()
        ) != nil
    }

    private func standardCompletions(for request: CompletionRequest) -> CompletionResult {
        let parsed = ShellCompletionParser.parse(input: request.input, cursorOffset: request.cursorOffset)
        var diagnostics: [String] = []

        if parsed.commandTokenIndex == nil || parsed.isCompletingCommand {
            let suggestions = commandSuggestions(prefix: parsed.currentTokenText, request: request)
                .limited(to: request.limit)
            return CompletionResult(
                replacementRange: parsed.currentTokenRange,
                suggestions: suggestions,
                commonPrefix: commonPrefix(for: suggestions, strippingTrailingSpace: true),
                diagnostics: diagnostics
            )
        }

        guard let commandIndex = parsed.commandTokenIndex else {
            return emptyResult(range: parsed.currentTokenRange)
        }

        let commandName = (parsed.tokens[commandIndex].text as NSString).lastPathComponent
        let argumentTokens = Array(parsed.tokens.dropFirst(commandIndex + 1))
        let currentPrefix = parsed.currentTokenText
        var suggestions: [CompletionSuggestion] = []
        let hasFigSpec = specLoader.hasSpec(command: commandName)

        let useNativePathCompletion = shouldUseNativePathCompletion(
            commandName: commandName,
            currentPrefix: currentPrefix,
            hasFigSpec: hasFigSpec
        )

        if useNativePathCompletion {
            let nativeSuggestions = rankedSuggestions(pathSuggestions(
                prefix: currentPrefix,
                request: request,
                foldersOnly: commandName == "cd"
            ), prefix: currentPrefix, limit: request.limit)
            return CompletionResult(
                replacementRange: parsed.currentTokenRange,
                suggestions: nativeSuggestions,
                commonPrefix: commonPrefix(for: nativeSuggestions, strippingTrailingSpace: false),
                diagnostics: diagnostics
            )
        } else if let spec = specLoader.load(command: commandName) {
            suggestions.append(contentsOf: suggestionsFromSpec(
                spec,
                commandName: commandName,
                argumentTokens: argumentTokens,
                currentPrefix: currentPrefix,
                request: request
            ))
        } else {
            diagnostics.append("No Fig spec for \(commandName)")
        }

        var deduped = rankedSuggestions(suggestions, prefix: currentPrefix, limit: request.limit)
        if deduped.isEmpty && shouldAddPathFallback(commandName: commandName, currentPrefix: currentPrefix) {
            deduped = rankedSuggestions(pathSuggestions(
                prefix: currentPrefix,
                request: request,
                foldersOnly: commandName == "cd"
            ), prefix: currentPrefix, limit: request.limit)
        }

        return CompletionResult(
            replacementRange: parsed.currentTokenRange,
            suggestions: deduped,
            commonPrefix: commonPrefix(for: deduped, strippingTrailingSpace: false),
            diagnostics: diagnostics
        )
    }

    private func historySuggestions(for request: CompletionRequest) -> [CompletionSuggestion] {
        guard let input = try? JSONEncoder().encode(BridgeHistoryQueryRequest(
            cwd: request.cwd,
            prefix: request.input,
            limit: request.limit
        )),
        let output = runHostBridge(
            operation: .queryHistory,
            input: input,
            location: request.location,
            relayProvider: request.relayProvider,
            timeout: 2,
            cancellation: request.cancellation
        ),
        let response = try? JSONDecoder().decode(BridgeCompletionResponse.self, from: output)
        else {
            return []
        }
        let range = NSRange(location: 0, length: (request.input as NSString).length)
        return response.suggestions.map { bridge in
            CompletionSuggestion(
                displayText: bridge.displayText,
                insertText: bridge.insertText,
                description: bridge.description,
                kind: .history,
                priority: bridge.priority,
                source: bridge.source,
                replacementRange: range
            )
        }
    }

    private func runHostBridge(
        operation: RemoteCompletionOperation,
        input: Data,
        location: SessionLocation,
        relayProvider: RelayCompletionProvider?,
        timeout: TimeInterval,
        cancellation: CompletionCancellation
    ) -> Data? {
        do {
            switch location {
            case .local:
                return try PtySession.runLocalBridgeSubcommand(
                    arguments: [operation.rawValue],
                    input: input,
                    timeout: timeout
                )
            case .sshHost(let hostID):
                return try PtySession.runSSHBridgeSubcommand(
                    hostID: hostID,
                    arguments: [operation.rawValue],
                    input: input,
                    timeout: timeout
                )
            case .relayMac:
                return relayProvider?.run(
                    operation: operation,
                    input: input,
                    timeout: timeout,
                    cancellation: cancellation
                )
            }
        } catch {
            return nil
        }
    }

    private func emptyResult(range: NSRange) -> CompletionResult {
        CompletionResult(replacementRange: range, suggestions: [], commonPrefix: nil, diagnostics: [])
    }

    private func suggestionsFromSpec(
        _ spec: LoadedFigSpec,
        commandName: String,
        argumentTokens: [ShellCompletionParser.Token],
        currentPrefix: String,
        request: CompletionRequest
    ) -> [CompletionSuggestion] {
        var activeSpec = spec
        var node = FigNode(value: activeSpec.value)
        let consumed = max(0, argumentTokens.count - 1)
        var pendingOptionArgs: [FigArg] = []
        var positionalArgIndex = 0

        if consumed > 0 {
            for token in argumentTokens.prefix(consumed) {
                if !pendingOptionArgs.isEmpty {
                    pendingOptionArgs.removeFirst()
                    continue
                }
                if token.text == "--" {
                    continue
                }
                if token.text.hasPrefix("-"),
                   let option = node.option(named: optionName(from: token.text)) {
                    pendingOptionArgs = option.args
                    continue
                }
                if let subcommand = node.subcommand(named: token.text) {
                    if let loadSpec = subcommand.loadSpec,
                       let loaded = specLoader.loadSpec(loadSpec) {
                        activeSpec = loaded
                        node = FigNode(value: loaded.value)
                    } else {
                        node = subcommand
                    }
                    positionalArgIndex = 0
                    pendingOptionArgs.removeAll()
                    continue
                }
                positionalArgIndex += 1
            }
        }

        var suggestions: [CompletionSuggestion] = []
        if currentPrefix.hasPrefix("-") || (currentPrefix.isEmpty && node.subcommands.isEmpty) {
            suggestions.append(contentsOf: node.options.flatMap { option in
                option.names.map {
                    CompletionSuggestion(
                        displayText: $0,
                        insertText: $0 + " ",
                        description: option.description,
                        kind: .option,
                        priority: 90,
                        source: commandName
                    )
                }
            })
        } else {
            suggestions.append(contentsOf: node.subcommands.flatMap { subcommand in
                subcommand.names.map {
                    CompletionSuggestion(
                        displayText: $0,
                        insertText: $0 + " ",
                        description: subcommand.description,
                        kind: .subcommand,
                        priority: 85,
                        source: commandName
                    )
                }
            })

            let arg = pendingOptionArgs.first ?? node.argument(at: positionalArgIndex)
            if let arg {
                suggestions.append(contentsOf: suggestionsFromArg(
                    arg,
                    commandName: commandName,
                    currentPrefix: currentPrefix,
                    request: request,
                    spec: activeSpec
                ))
            }
        }

        return suggestions
    }

    private func suggestionsFromArg(
        _ arg: FigArg,
        commandName: String,
        currentPrefix: String,
        request: CompletionRequest,
        spec: LoadedFigSpec
    ) -> [CompletionSuggestion] {
        var suggestions: [CompletionSuggestion] = []

        suggestions.append(contentsOf: arg.suggestions.map { suggestion in
            CompletionSuggestion(
                displayText: suggestion.name,
                insertText: (suggestion.insertValue ?? suggestion.name) + " ",
                description: suggestion.description,
                kind: .argument,
                priority: suggestion.priority,
                source: commandName
            )
        })

        for template in arg.templates {
            if template == "folders" {
                suggestions.append(contentsOf: pathSuggestions(prefix: currentPrefix, request: request, foldersOnly: true))
            } else if template == "filepaths" {
                suggestions.append(contentsOf: pathSuggestions(prefix: currentPrefix, request: request, foldersOnly: false))
            }
        }

        for generator in arg.generators {
            suggestions.append(contentsOf: suggestionsFromGenerator(
                generator,
                commandName: commandName,
                currentPrefix: currentPrefix,
                request: request,
                spec: spec
            ))
        }

        return suggestions
    }

    private func suggestionsFromGenerator(
        _ generator: FigGenerator,
        commandName: String,
        currentPrefix: String,
        request: CompletionRequest,
        spec: LoadedFigSpec
    ) -> [CompletionSuggestion] {
        guard !isRemotePathPrefix(currentPrefix) else {
            return []
        }

        var suggestions: [CompletionSuggestion] = []
        for template in generator.templates {
            if template == "folders" {
                suggestions.append(contentsOf: pathSuggestions(prefix: currentPrefix, request: request, foldersOnly: true))
            } else if template == "filepaths" {
                suggestions.append(contentsOf: pathSuggestions(prefix: currentPrefix, request: request, foldersOnly: false))
            }
        }

        suggestions.append(contentsOf: generator.suggestions.map { suggestion in
            CompletionSuggestion(
                displayText: suggestion.name,
                insertText: (suggestion.insertValue ?? suggestion.name) + " ",
                description: suggestion.description,
                kind: .argument,
                priority: suggestion.priority,
                source: commandName
            )
        })

        if let script = generator.script {
            suggestions.append(contentsOf: runScriptGenerator(
                script,
                generator: generator,
                commandName: commandName,
                request: request,
                spec: spec
            ))
        }

        if let custom = generator.custom, custom.isObject {
            suggestions.append(contentsOf: runCustomGenerator(
                custom,
                generator: generator,
                commandName: commandName,
                request: request,
                spec: spec
            ))
        }

        return suggestions
    }

    private func runScriptGenerator(
        _ script: FigScript,
        generator: FigGenerator,
        commandName: String,
        request: CompletionRequest,
        spec: LoadedFigSpec
    ) -> [CompletionSuggestion] {
        guard let output = ShellCommandRunner.runShell(
            commandLine: script.commandLine,
            cwd: script.cwd ?? request.cwd,
            environment: request.environment,
            timeout: timeout(for: generator),
            outputLimit: 64 * 1024,
            location: request.location,
            relayProvider: request.relayProvider,
            cancellation: request.cancellation
        ) else {
            return []
        }

        if let postProcess = generator.postProcess, postProcess.isObject {
            let value = postProcess.call(withArguments: [output.stdout.trimmingTrailingLineBreaks(), request.input])
            return suggestions(from: value, kind: .argument, source: commandName)
        }

        let splitOn = generator.splitOn ?? "\n"
        return output.stdout
            .components(separatedBy: splitOn)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                CompletionSuggestion(
                    displayText: $0,
                    insertText: $0 + " ",
                    description: nil,
                    kind: .argument,
                    priority: 50,
                    source: commandName
                )
            }
    }

    private func runCustomGenerator(
        _ custom: JSValue,
        generator: FigGenerator,
        commandName: String,
        request: CompletionRequest,
        spec: LoadedFigSpec
    ) -> [CompletionSuggestion] {
        let commandTimeout = timeout(for: generator)
        let executeCommand: @convention(block) (JSValue) -> JSValue = { [request] commandValue in
            let command = FigReader.string(commandValue.forProperty("command"))
            let argsValue = commandValue.forProperty("args")
            let cwd = FigReader.string(commandValue.forProperty("cwd")) ?? request.cwd
            let args = FigReader.stringArray(argsValue)
            guard let command,
                  let output = ShellCommandRunner.runShell(
                    commandLine: "noglob " + ([command] + args).joined(separator: " "),
                    cwd: cwd,
                    environment: request.environment,
                    timeout: commandTimeout,
                    outputLimit: 64 * 1024,
                    location: request.location,
                    relayProvider: request.relayProvider,
                    cancellation: request.cancellation
                  )
            else {
                return JSValue(object: ["stdout": "", "stderr": "", "status": 1], in: commandValue.context)!
            }
            return JSValue(
                object: ["stdout": output.stdout, "stderr": output.stderr, "status": output.status],
                in: commandValue.context
            )!
        }

        spec.context.setObject(executeCommand, forKeyedSubscript: "__vaulttyExecuteCommand" as NSString)
        spec.context.setObject(["currentWorkingDirectory": request.cwd, "searchTerm": request.input], forKeyedSubscript: "__vaulttyGeneratorContext" as NSString)
        spec.context.setObject(request.input.split(whereSeparator: { $0.isWhitespace }).map(String.init), forKeyedSubscript: "__vaulttyTokens" as NSString)
        spec.context.setObject(custom, forKeyedSubscript: "__vaulttyCustom" as NSString)

        let runner = """
        (function() {
          var box = { done: false, result: null, error: null };
          try {
            Promise.resolve(__vaulttyCustom(__vaulttyTokens, __vaulttyExecuteCommand, __vaulttyGeneratorContext)).then(function(result) {
              box.result = result;
              box.done = true;
            }, function(error) {
              box.error = String(error);
              box.done = true;
            });
          } catch (error) {
            box.error = String(error);
            box.done = true;
          }
          return box;
        })()
        """
        guard let box = spec.context.evaluateScript(runner), !box.isUndefined else {
            return []
        }

        let deadline = Date().addingTimeInterval(commandTimeout)
        while Date() < deadline {
            if box.forProperty("done")?.toBool() == true {
                return suggestions(from: box.forProperty("result"), kind: .argument, source: commandName)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return []
    }

    private func timeout(for generator: FigGenerator) -> TimeInterval {
        guard let scriptTimeout = generator.scriptTimeout else {
            return Self.defaultGeneratorTimeout
        }
        return min(max(scriptTimeout / 1000, 0), Self.maxGeneratorTimeout)
    }

    private func suggestions(from value: JSValue?, kind: CompletionSuggestion.Kind, source: String) -> [CompletionSuggestion] {
        guard let value, !value.isUndefined, !value.isNull else { return [] }
        if value.isString {
            let name = value.toString() ?? ""
            return name.isEmpty ? [] : [
                CompletionSuggestion(displayText: name, insertText: name + " ", description: nil, kind: kind, priority: 50, source: source)
            ]
        }
        return FigReader.arrayValues(value, limit: Self.maxGeneratorSuggestionCandidates).compactMap { item in
            if item.isString, let name = item.toString(), !name.isEmpty {
                return CompletionSuggestion(displayText: name, insertText: name + " ", description: nil, kind: kind, priority: 50, source: source)
            }
            guard let name = FigReader.names(from: item).first else { return nil }
            let insertValue = FigReader.string(item.forProperty("insertValue")) ?? name
            return CompletionSuggestion(
                displayText: name,
                insertText: insertValue + " ",
                description: FigReader.string(item.forProperty("description")),
                kind: kind,
                priority: Int(item.forProperty("priority")?.toInt32() ?? 50),
                source: source
            )
        }
    }

    private func commandSuggestions(prefix: String, request: CompletionRequest) -> [CompletionSuggestion] {
        if shouldCompleteCommandAsPath(prefix: prefix) {
            return rankedSuggestions(
                commandPathSuggestions(prefix: prefix, request: request),
                prefix: prefix,
                limit: request.limit
            )
        }

        let cacheKey = commandCacheKey(for: request)
        if let cached = commandCache[cacheKey] {
            return rankedSuggestions(cached, prefix: prefix, limit: request.limit)
        }

        var names = Set<String>()
        let executableSources = executableCommandSources(for: request)
        names.formUnion(specLoader.commandNames())
        names.formUnion(executableSources.keys)

        let suggestions = names.map { name in
            let hasSpec = specLoader.hasSpec(command: name)
            return CompletionSuggestion(
                displayText: name,
                insertText: name + " ",
                description: commandDescriptions.description(for: name),
                kind: .command,
                priority: hasSpec ? 70 : 50,
                source: hasSpec ? "Fig" : (executableSources[name] ?? "PATH")
            )
        }
        commandCache[cacheKey] = suggestions
        return rankedSuggestions(suggestions, prefix: prefix, limit: request.limit)
    }

    private func commandCacheKey(for request: CompletionRequest) -> String {
        switch request.location {
        case .local:
            return "local:\(request.shellPath):\(request.environment["PATH"] ?? "")"
        case .sshHost(let hostID):
            return "ssh:\(hostID)"
        case .relayMac(let macID):
            return "relay:\(macID):\(request.relayProvider?.cacheIdentity ?? "none")"
        }
    }

    private func executableCommandSources(for request: CompletionRequest) -> [String: String] {
        switch request.location {
        case .local:
            var sources: [String: String] = [:]
            let loginPath = ShellCommandRunner.loginPath(
                shellPath: request.shellPath,
                environment: request.environment
            )
            let path = [loginPath, request.environment["PATH"]]
                .compactMap { $0 }
                .joined(separator: ":")
            for directory in path.split(separator: ":").map(String.init) {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
                for name in contents {
                    let path = (directory as NSString).appendingPathComponent(name)
                    if sources[name] == nil && fileManager.isExecutableFile(atPath: path) {
                        sources[name] = path
                    }
                }
            }
            return sources
        case .sshHost(let hostID):
            let request = BridgeCommandCompletionRequest(prefix: "")
            guard let response: BridgeCompletionResponse = runBridgeJSON(
                hostID: hostID,
                subcommand: "complete-commands",
                request: request,
                timeout: 2
            ) else {
                return [:]
            }
            var sources: [String: String] = [:]
            for suggestion in response.suggestions where sources[suggestion.displayText] == nil {
                sources[suggestion.displayText] = suggestion.source
            }
            return sources
        case .relayMac:
            let bridgeRequest = BridgeCommandCompletionRequest(prefix: "")
            guard let response: BridgeCompletionResponse = runRelayBridgeJSON(
                operation: .completeCommands,
                request: bridgeRequest,
                timeout: 2,
                completionRequest: request
            ) else {
                return [:]
            }
            return Dictionary(
                response.suggestions.map { ($0.displayText, $0.source) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    private func shouldCompleteCommandAsPath(prefix: String) -> Bool {
        prefix.contains("/")
    }

    private func commandPathSuggestions(prefix: String, request: CompletionRequest) -> [CompletionSuggestion] {
        switch request.location {
        case .local:
            return pathSuggestions(prefix: prefix, request: request, foldersOnly: false).filter { suggestion in
                switch suggestion.kind {
                case .folder:
                    return true
                case .file:
                    let executablePath = (suggestion.source as NSString)
                        .appendingPathComponent(suggestion.displayText)
                    return fileManager.isExecutableFile(atPath: executablePath)
                default:
                    return false
                }
            }
        case .sshHost(let hostID):
            return remotePathSuggestionPayloads(
                hostID: hostID,
                prefix: prefix,
                cwd: request.cwd,
                foldersOnly: false
            )
            .filter { $0.kind == "folder" || $0.isExecutable }
            .map(completionSuggestion)
        case .relayMac:
            return relayPathSuggestionPayloads(
                prefix: prefix,
                cwd: request.cwd,
                foldersOnly: false,
                request: request
            )
            .filter { $0.kind == "folder" || $0.isExecutable }
            .map(completionSuggestion)
        }
    }

    private func pathSuggestions(prefix: String, request: CompletionRequest, foldersOnly: Bool) -> [CompletionSuggestion] {
        switch request.location {
        case .local:
            return localPathSuggestions(prefix: prefix, cwd: request.cwd, foldersOnly: foldersOnly)
        case .sshHost(let hostID):
            return remotePathSuggestionPayloads(
                hostID: hostID,
                prefix: prefix,
                cwd: request.cwd,
                foldersOnly: foldersOnly
            )
            .map(completionSuggestion)
        case .relayMac:
            return relayPathSuggestionPayloads(
                prefix: prefix,
                cwd: request.cwd,
                foldersOnly: foldersOnly,
                request: request
            )
            .map(completionSuggestion)
        }
    }

    private func localPathSuggestions(prefix: String, cwd: String, foldersOnly: Bool) -> [CompletionSuggestion] {
        guard !isRemotePathPrefix(prefix) else {
            return []
        }

        let expanded = expandTilde(prefix)
        let nsPrefix = expanded as NSString
        let directoryPart = nsPrefix.deletingLastPathComponent
        let filePrefix = expanded.hasSuffix("/") ? "" : nsPrefix.lastPathComponent
        let directory: String
        if expanded.hasSuffix("/") {
            directory = expanded.hasPrefix("/")
                ? expanded
                : (cwd as NSString).appendingPathComponent(expanded)
        } else if directoryPart.isEmpty || directoryPart == "." {
            directory = cwd
        } else if directoryPart.hasPrefix("/") {
            directory = directoryPart
        } else {
            directory = (cwd as NSString).appendingPathComponent(directoryPart)
        }

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var suggestions: [CompletionSuggestion] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name != "." && name != ".." else { continue }
            if !filePrefix.hasPrefix("."), name.hasPrefix(".") {
                continue
            }
            guard filePrefix.isEmpty || hasCaseInsensitivePrefix(name, filePrefix) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory || !foldersOnly else { continue }

            let visibleName = name + (isDirectory ? "/" : "")
            let inserted = pathInsertValue(prefix: prefix, suggestionName: visibleName, isDirectory: isDirectory)
            suggestions.append(CompletionSuggestion(
                displayText: visibleName,
                insertText: inserted,
                description: nil,
                kind: isDirectory ? .folder : .file,
                priority: isDirectory ? 60 : 55,
                source: directory
            ))
            if suggestions.count >= Self.maxPathSuggestionCandidates {
                break
            }
        }
        return suggestions
    }

    private func remotePathSuggestionPayloads(
        hostID: String,
        prefix: String,
        cwd: String,
        foldersOnly: Bool
    ) -> [BridgeCompletionSuggestion] {
        guard !isRemotePathPrefix(prefix) else {
            return []
        }

        let request = BridgePathCompletionRequest(cwd: cwd, prefix: prefix, foldersOnly: foldersOnly)
        guard let response: BridgeCompletionResponse = runBridgeJSON(
            hostID: hostID,
            subcommand: "complete-path",
            request: request,
            timeout: 2
        ) else {
            return []
        }
        return response.suggestions
    }

    private func relayPathSuggestionPayloads(
        prefix: String,
        cwd: String,
        foldersOnly: Bool,
        request: CompletionRequest
    ) -> [BridgeCompletionSuggestion] {
        guard !isRemotePathPrefix(prefix) else { return [] }
        let bridgeRequest = BridgePathCompletionRequest(
            cwd: cwd,
            prefix: prefix,
            foldersOnly: foldersOnly
        )
        let response: BridgeCompletionResponse? = runRelayBridgeJSON(
            operation: .completePath,
            request: bridgeRequest,
            timeout: 2,
            completionRequest: request
        )
        return response?.suggestions ?? []
    }

    private func completionSuggestion(from bridge: BridgeCompletionSuggestion) -> CompletionSuggestion {
        CompletionSuggestion(
            displayText: bridge.displayText,
            insertText: bridge.insertText,
            description: bridge.description,
            kind: completionKind(from: bridge.kind),
            priority: bridge.priority,
            source: bridge.source
        )
    }

    private func completionKind(from value: String) -> CompletionSuggestion.Kind {
        switch value {
        case "history":
            return .history
        case "command":
            return .command
        case "subcommand":
            return .subcommand
        case "option":
            return .option
        case "folder":
            return .folder
        case "file":
            return .file
        default:
            return .argument
        }
    }

    private func runBridgeJSON<Request: Encodable, Response: Decodable>(
        hostID: String,
        subcommand: String,
        request: Request,
        timeout: TimeInterval
    ) -> Response? {
        do {
            let input = try JSONEncoder().encode(request)
            let output = try PtySession.runSSHBridgeSubcommand(
                hostID: hostID,
                arguments: [subcommand],
                input: input,
                timeout: timeout
            )
            return try JSONDecoder().decode(Response.self, from: output)
        } catch {
            return nil
        }
    }

    private func runRelayBridgeJSON<Request: Encodable, Response: Decodable>(
        operation: RemoteCompletionOperation,
        request: Request,
        timeout: TimeInterval,
        completionRequest: CompletionRequest
    ) -> Response? {
        guard let provider = completionRequest.relayProvider,
              let input = try? JSONEncoder().encode(request),
              let output = provider.run(
                operation: operation,
                input: input,
                timeout: timeout,
                cancellation: completionRequest.cancellation
              )
        else {
            return nil
        }
        return try? JSONDecoder().decode(Response.self, from: output)
    }

    private func pathInsertValue(prefix: String, suggestionName: String, isDirectory: Bool) -> String {
        let basePrefix: String
        if prefix.hasSuffix("/") {
            basePrefix = prefix
        } else {
            let nsPrefix = prefix as NSString
            let directoryName = nsPrefix.deletingLastPathComponent
            if directoryName.isEmpty {
                basePrefix = ""
            } else if directoryName == "/" {
                basePrefix = "/"
            } else if directoryName == "." {
                basePrefix = prefix.hasPrefix("./") ? "./" : ""
            } else {
                basePrefix = directoryName + "/"
            }
        }
        let raw = basePrefix + suggestionName
        return shellEscapePath(raw) + (isDirectory ? "" : " ")
    }

    private func shouldAddPathFallback(commandName: String, currentPrefix: String) -> Bool {
        commandName == "cd" || commandName == "ls" || currentPrefix.contains("/")
    }

    private func shouldUseNativePathCompletion(commandName: String, currentPrefix: String, hasFigSpec: Bool) -> Bool {
        guard !isRemotePathPrefix(currentPrefix) else {
            return false
        }
        if commandName == "cd" {
            return true
        }
        if commandName == "ls", !currentPrefix.hasPrefix("-") {
            return true
        }
        return currentPrefix.contains("/") && !hasFigSpec
    }

    private func isRemotePathPrefix(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":") else {
            return false
        }
        let hostPart = value[..<colon]
        return !hostPart.isEmpty && !hostPart.contains("/")
    }

    private func isHiddenPathSuggestion(_ suggestion: CompletionSuggestion) -> Bool {
        switch suggestion.kind {
        case .file, .folder:
            return suggestion.displayText.hasPrefix(".")
        default:
            return false
        }
    }

    private func optionName(from token: String) -> String {
        token.components(separatedBy: "=").first ?? token
    }

    private func dedupe(_ suggestions: [CompletionSuggestion]) -> [CompletionSuggestion] {
        var seen = Set<String>()
        var output: [CompletionSuggestion] = []
        for suggestion in suggestions {
            let key = "\(suggestion.kind.label):\(suggestion.displayText):\(suggestion.insertText)"
            if seen.insert(key).inserted {
                output.append(suggestion)
            }
        }
        return output
    }

    private func rankedSuggestions(_ suggestions: [CompletionSuggestion], prefix: String, limit: Int) -> [CompletionSuggestion] {
        dedupe(suggestions)
            .filter { matches(prefix: prefix, suggestion: $0) }
            .sorted { left, right in
                if isHiddenPathSuggestion(left) != isHiddenPathSuggestion(right) {
                    return !isHiddenPathSuggestion(left)
                }
                let leftExact = isExactMatch(prefix: prefix, suggestion: left)
                let rightExact = isExactMatch(prefix: prefix, suggestion: right)
                if leftExact != rightExact { return leftExact }
                if left.priority != right.priority { return left.priority > right.priority }
                return left.displayText.localizedStandardCompare(right.displayText) == .orderedAscending
            }
            .limited(to: limit)
    }

    private func matches(prefix: String, candidate: String) -> Bool {
        prefix.isEmpty || hasCaseInsensitivePrefix(candidate, prefix)
    }

    private func matches(prefix: String, suggestion: CompletionSuggestion) -> Bool {
        if matches(prefix: prefix, candidate: suggestion.displayText) {
            return true
        }
        switch suggestion.kind {
        case .file, .folder:
            return matches(prefix: prefix, candidate: suggestion.insertText.replacingOccurrences(of: "\\", with: ""))
        default:
            return false
        }
    }

    private func isExactMatch(prefix: String, suggestion: CompletionSuggestion) -> Bool {
        guard !prefix.isEmpty else { return false }
        if equalsIgnoringCase(suggestion.displayText, prefix) {
            return true
        }

        let insertText = suggestion.insertText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch suggestion.kind {
        case .file, .folder:
            return equalsIgnoringCase(insertText.replacingOccurrences(of: "\\", with: ""), prefix)
        default:
            return equalsIgnoringCase(insertText, prefix)
        }
    }

    private func hasCaseInsensitivePrefix(_ value: String, _ prefix: String) -> Bool {
        value.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
    }

    private func equalsIgnoringCase(_ left: String, _ right: String) -> Bool {
        left.compare(right, options: [.caseInsensitive]) == .orderedSame
    }

    private func commonPrefix(for suggestions: [CompletionSuggestion], strippingTrailingSpace: Bool) -> String? {
        guard suggestions.count > 1 else { return nil }
        let values = suggestions.map {
            strippingTrailingSpace ? $0.insertText.trimmingCharacters(in: .whitespaces) : $0.insertText
        }
        guard var prefix = values.first else { return nil }
        for value in values.dropFirst() {
            while !value.hasPrefix(prefix), !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        return prefix.isEmpty ? nil : prefix
    }

    private func expandTilde(_ value: String) -> String {
        if value == "~" {
            return fileManager.homeDirectoryForCurrentUser.path
        }
        if value.hasPrefix("~/") {
            return fileManager.homeDirectoryForCurrentUser.path + String(value.dropFirst())
        }
        return value
    }

    private func shellEscapePath(_ value: String) -> String {
        var output = ""
        for character in value {
            if character.isWhitespace || "\\'\"$`!*?[]{}()&;|<>".contains(character) {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }
}

private extension Array {
    func limited(to limit: Int) -> [Element] {
        limit > 0 && count > limit ? Array(prefix(limit)) : self
    }
}

enum ShellCompletionParser {
    struct Token {
        let text: String
        let range: NSRange
        let quote: Character?
    }

    struct ParsedCommand {
        let tokens: [Token]
        let currentTokenText: String
        let currentTokenRange: NSRange
        let commandTokenIndex: Int?
        let isCompletingCommand: Bool
    }

    static func parse(input: String, cursorOffset: Int) -> ParsedCommand {
        let nsInput = input as NSString
        let clampedCursor = max(0, min(cursorOffset, nsInput.length))
        let prefix = nsInput.substring(to: clampedCursor)
        let segment = activeSegment(in: prefix)
        let segmentOffset = clampedCursor - (segment as NSString).length
        let tokens = tokenize(segment: segment, segmentOffset: segmentOffset)
        let current = currentToken(tokens: tokens, cursorOffset: clampedCursor)
        let commandIndex = commandTokenIndex(in: tokens)
        let isCompletingCommand = commandIndex == nil || current.index == commandIndex
        return ParsedCommand(
            tokens: tokens,
            currentTokenText: current.token?.text ?? "",
            currentTokenRange: current.token?.range ?? NSRange(location: clampedCursor, length: 0),
            commandTokenIndex: commandIndex,
            isCompletingCommand: isCompletingCommand
        )
    }

    private static func activeSegment(in value: String) -> String {
        var quote: Character?
        var escape = false
        var lastBreak = value.startIndex

        for index in value.indices {
            let character = value[index]
            if escape {
                escape = false
                continue
            }
            if character == "\\" {
                escape = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == ";" || character == "|" || character == "\n" {
                lastBreak = value.index(after: index)
            }
        }

        return String(value[lastBreak...])
    }

    private static func tokenize(segment: String, segmentOffset: Int) -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var tokenStart: Int?
        var quote: Character?
        var tokenQuote: Character?
        var escape = false
        var utf16Offset = segmentOffset

        func flush(at location: Int) {
            guard let start = tokenStart else { return }
            tokens.append(Token(text: text, range: NSRange(location: start, length: max(0, location - start)), quote: tokenQuote))
            text = ""
            tokenStart = nil
            tokenQuote = nil
        }

        for character in segment {
            let width = String(character).utf16.count
            if escape {
                if tokenStart == nil { tokenStart = utf16Offset }
                text.append(character)
                escape = false
                utf16Offset += width
                continue
            }
            if character == "\\" {
                if tokenStart == nil { tokenStart = utf16Offset }
                escape = true
                utf16Offset += width
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    text.append(character)
                }
                utf16Offset += width
                continue
            }
            if character == "\"" || character == "'" {
                if tokenStart == nil { tokenStart = utf16Offset }
                quote = character
                tokenQuote = character
                utf16Offset += width
                continue
            }
            if character.isWhitespace {
                flush(at: utf16Offset)
                utf16Offset += width
                continue
            }
            if tokenStart == nil { tokenStart = utf16Offset }
            text.append(character)
            utf16Offset += width
        }
        flush(at: utf16Offset)

        if segment.last?.isWhitespace == true {
            tokens.append(Token(text: "", range: NSRange(location: segmentOffset + (segment as NSString).length, length: 0), quote: nil))
        } else if tokens.isEmpty {
            tokens.append(Token(text: "", range: NSRange(location: segmentOffset, length: 0), quote: nil))
        }
        return tokens
    }

    private static func currentToken(tokens: [Token], cursorOffset: Int) -> (token: Token?, index: Int?) {
        for (index, token) in tokens.enumerated() {
            if cursorOffset >= token.range.location && cursorOffset <= token.range.location + token.range.length {
                return (token, index)
            }
        }
        return (tokens.last, tokens.indices.last)
    }

    private static func commandTokenIndex(in tokens: [Token]) -> Int? {
        var index = 0
        let wrappers = Set(["builtin", "command", "exec", "noglob", "sudo"])

        while index < tokens.count {
            let text = tokens[index].text
            if text.isEmpty {
                return index
            }
            if isAssignment(text) {
                index += 1
                continue
            }
            if text == "env" {
                index += 1
                while index < tokens.count && (isAssignment(tokens[index].text) || tokens[index].text.hasPrefix("-")) {
                    index += 1
                }
                continue
            }
            if wrappers.contains((text as NSString).lastPathComponent) {
                index += 1
                if text == "sudo" {
                    while index < tokens.count && tokens[index].text.hasPrefix("-") {
                        index += 1
                    }
                }
                continue
            }
            return index
        }
        return tokens.indices.last
    }

    private static func isAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else { return false }
        let key = value[..<equals]
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

private final class FigSpecLoader {
    private var specsRoot: URL?
    private var index: [String: URL]?
    private var cache: [String: LoadedFigSpec] = [:]

    init() {
        if let override = ProcessInfo.processInfo.environment["VAULTTY_COMPLETIONS_DIR"], !override.isEmpty {
            specsRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            specsRoot = Bundle.main.resourceURL?
                .appendingPathComponent("completions", isDirectory: true)
                .appendingPathComponent("fig", isDirectory: true)
                .appendingPathComponent("build", isDirectory: true)
        }
    }

    func commandNames() -> [String] {
        Array(specIndex().keys)
    }

    func hasSpec(command: String) -> Bool {
        specIndex()[command] != nil
    }

    func load(command: String) -> LoadedFigSpec? {
        if let cached = cache[command] {
            return cached
        }
        guard let url = specIndex()[command],
              let loaded = load(cacheKey: command, url: url)
        else {
            return nil
        }
        return loaded
    }

    func loadSpec(_ path: String) -> LoadedFigSpec? {
        let key = "spec:\(path)"
        if let cached = cache[key] {
            return cached
        }
        guard let specsRoot,
              let url = specURL(path, relativeTo: specsRoot)
        else {
            return nil
        }
        return load(cacheKey: key, url: url)
    }

    private func load(cacheKey: String, url: URL) -> LoadedFigSpec? {
        guard
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let transformed = transformModule(contents)
        else {
            return nil
        }

        let context = JSContext()
        context?.exceptionHandler = { _, _ in }
        context?.evaluateScript("""
        globalThis.console = { log: function(){}, warn: function(){}, error: function(){}, debug: function(){} };
        globalThis.process = { env: {} };
        """)
        guard let context else { return nil }
        _ = context.evaluateScript(transformed)
        guard context.objectForKeyedSubscript("__vaulttyDefaultException")?.isUndefined != false,
              let defaultValue = context.objectForKeyedSubscript("__vaulttyDefault"),
              !defaultValue.isUndefined,
              !defaultValue.isNull
        else {
            return nil
        }
        let loaded = LoadedFigSpec(context: context, value: defaultValue)
        cache[cacheKey] = loaded
        return loaded
    }

    private func specURL(_ path: String, relativeTo specsRoot: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        var url = specsRoot
        for component in path.split(separator: "/") {
            guard component != ".." else { return nil }
            url.appendPathComponent(String(component), isDirectory: false)
        }
        url.appendPathExtension("js")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func specIndex() -> [String: URL] {
        if let index { return index }
        guard let specsRoot else {
            index = [:]
            return [:]
        }
        var output: [String: URL] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: specsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            index = [:]
            return [:]
        }

        let specsRootPath = specsRoot.standardizedFileURL.path
        for case let url as URL in enumerator where url.pathExtension == "js" {
            guard url.deletingLastPathComponent().standardizedFileURL.path == specsRootPath else { continue }
            output[url.deletingPathExtension().lastPathComponent] = url
        }
        index = output
        return output
    }

    private func transformModule(_ source: String) -> String? {
        if let range = source.range(of: #"export\s*\{([^}]*)\}\s*;?\s*$"#, options: .regularExpression) {
            let exportClause = String(source[range])
            guard let defaultName = defaultExportName(from: exportClause) else { return nil }
            var transformed = source
            transformed.replaceSubrange(range, with: "\nglobalThis.__vaulttyDefault = \(defaultName);")
            return transformed
        }
        if let range = source.range(of: #"export\s+default\s+([^;]+);?\s*$"#, options: .regularExpression) {
            let exportStatement = String(source[range])
            let expression = exportStatement
                .replacingOccurrences(of: #"export\s+default\s+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\n\t"))
            var transformed = source
            transformed.replaceSubrange(range, with: "\nglobalThis.__vaulttyDefault = \(expression);")
            return transformed
        }
        return nil
    }

    private func defaultExportName(from exportClause: String) -> String? {
        let body = exportClause
            .replacingOccurrences(of: #"^export\s*\{"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\}\s*;?\s*$"#, with: "", options: .regularExpression)
        for part in body.split(separator: ",") {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = text.components(separatedBy: " as ")
            if pieces.count == 2 && pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) == "default" {
                return pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

private struct LoadedFigSpec {
    let context: JSContext
    let value: JSValue
}

private struct FigNode {
    let value: JSValue

    var names: [String] { FigReader.names(from: value) }
    var description: String? { FigReader.string(value.forProperty("description")) }
    var loadSpec: String? { FigReader.string(value.forProperty("loadSpec")) }
    var subcommands: [FigNode] { FigReader.arrayValues(value.forProperty("subcommands")).map(FigNode.init) }
    var options: [FigOption] { FigReader.arrayValues(value.forProperty("options")).map(FigOption.init) }
    var args: [FigArg] { FigReader.args(from: value.forProperty("args")) }

    func subcommand(named name: String) -> FigNode? {
        subcommands.first { $0.names.contains(name) }
    }

    func option(named name: String) -> FigOption? {
        options.first { $0.names.contains(name) }
    }

    func argument(at index: Int) -> FigArg? {
        let availableArgs = args
        guard !availableArgs.isEmpty else { return nil }
        if availableArgs.indices.contains(index) {
            return availableArgs[index]
        }
        guard let last = availableArgs.last, last.isVariadic else { return nil }
        return last
    }
}

private struct FigOption {
    let value: JSValue

    var names: [String] { FigReader.names(from: value) }
    var description: String? { FigReader.string(value.forProperty("description")) }
    var args: [FigArg] { FigReader.args(from: value.forProperty("args")) }
}

private struct FigArg {
    let value: JSValue

    var suggestions: [FigStaticSuggestion] {
        FigReader.suggestions(from: value.forProperty("suggestions"))
    }

    var templates: [String] {
        FigReader.templates(from: value)
    }

    var generators: [FigGenerator] {
        var generators = FigReader.arrayValues(value.forProperty("generators")).map(FigGenerator.init)
        if let generatorValue = value.forProperty("generator"), !generatorValue.isUndefined {
            generators.append(FigGenerator(value: generatorValue))
        }
        return generators
    }

    var isVariadic: Bool {
        value.forProperty("isVariadic")?.toBool() == true
    }
}

private extension String {
    func trimmingTrailingLineBreaks() -> String {
        var output = self
        while output.last == "\n" || output.last == "\r" {
            output.removeLast()
        }
        return output
    }
}

private struct FigGenerator {
    let value: JSValue

    var templates: [String] { FigReader.templates(from: value) }
    var suggestions: [FigStaticSuggestion] { FigReader.suggestions(from: value.forProperty("suggestions")) }
    var splitOn: String? { FigReader.string(value.forProperty("splitOn")) }
    var postProcess: JSValue? { value.forProperty("postProcess") }
    var custom: JSValue? { value.forProperty("custom") }
    var scriptTimeout: TimeInterval? {
        guard let timeout = value.forProperty("scriptTimeout"), !timeout.isUndefined, !timeout.isNull else {
            return nil
        }
        let milliseconds = timeout.toDouble()
        return milliseconds.isFinite ? milliseconds : nil
    }

    var script: FigScript? {
        guard let scriptValue = value.forProperty("script"), !scriptValue.isUndefined else { return nil }
        if scriptValue.isString, let command = scriptValue.toString() {
            return FigScript(commandLine: command, cwd: nil)
        }
        if scriptValue.isArray {
            let parts = FigReader.stringArray(scriptValue)
            guard let command = parts.first else { return nil }
            return FigScript(commandLine: "noglob " + ([command] + Array(parts.dropFirst())).joined(separator: " "), cwd: nil)
        }
        if scriptValue.isObject {
            let command = FigReader.string(scriptValue.forProperty("command"))
            let args = FigReader.stringArray(scriptValue.forProperty("args"))
            let cwd = FigReader.string(scriptValue.forProperty("cwd"))
            if let command {
                return FigScript(commandLine: "noglob " + ([command] + args).joined(separator: " "), cwd: cwd)
            }
        }
        return nil
    }
}

private struct FigScript {
    let commandLine: String
    let cwd: String?
}

private struct FigStaticSuggestion {
    let name: String
    let insertValue: String?
    let description: String?
    let priority: Int
}

private enum FigReader {
    static func arrayValues(_ value: JSValue?, limit: Int? = nil) -> [JSValue] {
        guard let value, !value.isUndefined, !value.isNull else { return [] }
        if value.isArray {
            let length = Int(value.forProperty("length")?.toInt32() ?? 0)
            let cappedLength = min(length, limit ?? length)
            return (0..<cappedLength).compactMap { value.atIndex($0) }
        }
        return value.isObject || value.isString ? [value] : []
    }

    static func args(from value: JSValue?) -> [FigArg] {
        arrayValues(value).map(FigArg.init)
    }

    static func names(from value: JSValue?) -> [String] {
        guard let value, !value.isUndefined, !value.isNull else { return [] }
        guard let nameValue = value.forProperty("name"), !nameValue.isUndefined else {
            return value.isString ? [value.toString()].compactMap { $0 } : []
        }
        return stringArray(nameValue)
    }

    static func stringArray(_ value: JSValue?) -> [String] {
        guard let value, !value.isUndefined, !value.isNull else { return [] }
        if value.isString {
            return [value.toString()].compactMap { $0 }
        }
        if value.isArray {
            return arrayValues(value).compactMap { string($0) }
        }
        return []
    }

    static func string(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }

    static func templates(from value: JSValue?) -> [String] {
        guard let value else { return [] }
        var templates: [String] = []
        templates.append(contentsOf: stringArray(value.forProperty("template")))
        templates.append(contentsOf: stringArray(value.forProperty("templates")))
        return templates
    }

    static func suggestions(from value: JSValue?) -> [FigStaticSuggestion] {
        arrayValues(value).compactMap { item in
            if item.isString, let name = item.toString(), !name.isEmpty {
                return FigStaticSuggestion(name: name, insertValue: nil, description: nil, priority: 50)
            }
            guard let name = names(from: item).first else { return nil }
            return FigStaticSuggestion(
                name: name,
                insertValue: string(item.forProperty("insertValue")),
                description: string(item.forProperty("description")),
                priority: Int(item.forProperty("priority")?.toInt32() ?? 50)
            )
        }
    }
}

private enum ShellCommandRunner {
    struct Output {
        let stdout: String
        let stderr: String
        let status: Int32
    }

    static func loginPath(shellPath: String, environment: [String: String]) -> String? {
        var environment = environment
        environment.removeValue(forKey: "PATH")
        let interactive = ["bash", "zsh"].contains(URL(fileURLWithPath: shellPath).lastPathComponent)
        return runLocalShell(
            commandLine: "printf '%s' \"$PATH\"",
            cwd: environment["HOME"] ?? "/",
            environment: environment,
            timeout: 2,
            outputLimit: 64 * 1024,
            shellPath: shellPath,
            interactive: interactive
        )?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func runShell(
        commandLine: String,
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        outputLimit: Int,
        location: SessionLocation,
        relayProvider: RelayCompletionProvider?,
        cancellation: CompletionCancellation
    ) -> Output? {
        switch location {
        case .local:
            return runLocalShell(
                commandLine: commandLine,
                cwd: cwd,
                environment: environment,
                timeout: timeout,
                outputLimit: outputLimit
            )
        case .sshHost(let hostID):
            return runRemoteShell(
                hostID: hostID,
                commandLine: commandLine,
                cwd: cwd,
                environment: environment,
                timeout: timeout,
                outputLimit: outputLimit
            )
        case .relayMac:
            return runRelayShell(
                provider: relayProvider,
                commandLine: commandLine,
                cwd: cwd,
                environment: environment,
                timeout: timeout,
                outputLimit: outputLimit,
                cancellation: cancellation
            )
        }
    }

    private static func runLocalShell(
        commandLine: String,
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        outputLimit: Int,
        shellPath: String = "/bin/zsh",
        interactive: Bool = false
    ) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = [interactive ? "-lic" : "-lc", shellPrelude(environment: environment) + commandLine]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        let stdoutCapture = LimitedPipeCapture(limit: outputLimit)
        let stderrCapture = LimitedPipeCapture(limit: outputLimit)
        process.standardOutput = stdoutCapture.pipe
        process.standardError = stderrCapture.pipe

        do {
            try process.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 0.15) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            _ = stdoutCapture.finish()
            _ = stderrCapture.finish()
            return nil
        }

        return Output(
            stdout: stdoutCapture.finish(),
            stderr: stderrCapture.finish(),
            status: process.terminationStatus
        )
    }

    private static func runRemoteShell(
        hostID: String,
        commandLine: String,
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        outputLimit: Int
    ) -> Output? {
        let request = BridgeGeneratorRequest(
            commandLine: commandLine,
            cwd: cwd,
            environment: environment
                .sorted { $0.key < $1.key }
                .map { BridgeGeneratorRequest.EnvironmentPair(key: $0.key, value: $0.value) },
            timeoutMs: Int((timeout * 1000).rounded()),
            outputLimit: outputLimit
        )
        do {
            let input = try JSONEncoder().encode(request)
            let output = try PtySession.runSSHBridgeSubcommand(
                hostID: hostID,
                arguments: ["run-generator"],
                input: input,
                timeout: min(max(timeout + 1, 2), 16)
            )
            let decoded = try JSONDecoder().decode(BridgeGeneratorOutput.self, from: output)
            return Output(stdout: decoded.stdout, stderr: decoded.stderr, status: decoded.status)
        } catch {
            return nil
        }
    }

    private static func runRelayShell(
        provider: RelayCompletionProvider?,
        commandLine: String,
        cwd: String,
        environment: [String: String],
        timeout: TimeInterval,
        outputLimit: Int,
        cancellation: CompletionCancellation
    ) -> Output? {
        let request = BridgeGeneratorRequest(
            commandLine: commandLine,
            cwd: cwd,
            environment: environment
                .sorted { $0.key < $1.key }
                .map { BridgeGeneratorRequest.EnvironmentPair(key: $0.key, value: $0.value) },
            timeoutMs: Int((timeout * 1000).rounded()),
            outputLimit: outputLimit
        )
        guard let provider,
              let input = try? JSONEncoder().encode(request),
              let output = provider.run(
                operation: .runGenerator,
                input: input,
                timeout: min(max(timeout + 1, 2), 16),
                cancellation: cancellation
              ),
              let decoded = try? JSONDecoder().decode(
                BridgeGeneratorOutput.self,
                from: output
              )
        else {
            return nil
        }
        return Output(
            stdout: decoded.stdout,
            stderr: decoded.stderr,
            status: decoded.status
        )
    }

    private static func shellPrelude(environment: [String: String]) -> String {
        guard let path = environment["PATH"], !path.isEmpty else {
            return ""
        }
        return "PATH=\(shellSingleQuote(path)); export PATH; "
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class LimitedPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.append(chunk)
        }
    }

    func finish() -> String {
        pipe.fileHandleForReading.readabilityHandler = nil
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            append(chunk)
        }
        let output: Data
        lock.lock()
        output = data
        lock.unlock()
        pipe.fileHandleForReading.closeFile()
        return String(decoding: output, as: UTF8.self)
    }

    private func append(_ chunk: Data) {
        guard limit > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - data.count
        guard remaining > 0 else { return }
        if chunk.count <= remaining {
            data.append(chunk)
        } else {
            data.append(chunk.prefix(remaining))
        }
    }
}
