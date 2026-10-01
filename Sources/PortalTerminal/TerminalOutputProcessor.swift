#if os(macOS)
import AppKit

final class TerminalOutputProcessor {
    struct Snapshot {
        let blockID: UUID
        let plainText: String
        let attributedText: NSAttributedString
        let isAlternateScreenActive: Bool
        let isApplicationCursorModeActive: Bool
        let mouseTrackingMode: Ansi.MouseTrackingMode?
        let usesSGRMouseMode: Bool
    }

    enum Event {
        case snapshot(Snapshot)
        case marker(PortalMarker, isReplay: Bool)
        case replayCommandStarted(blockID: UUID, command: String)
    }

    var onEvent: ((Event) -> Void)?
    var onTerminalResponse: ((String) -> Void)?

    private let queue = DispatchQueue(label: "dev.mxcl.portal.output-render", qos: .userInitiated)
    private let flushDelay: DispatchTimeInterval
    private let inputFeedbackFlushDelay: DispatchTimeInterval = .milliseconds(2)
    private let terminalScreen = Ansi.TerminalScreen(rows: 30, cols: 100)
    private let styledRenderer = Ansi.StyledTextRenderer(rows: 30)
    private var pendingShellOutput = ""
    // Queries must not wait behind transcript rendering: callers can stop reading replies.
    private let terminalResponseLock = NSLock()
    private var pendingTerminalQuery = ""
    private var terminalQueryPosition = (1, 1)
    private var terminalQuerySize = (30, 100)
    private var isShellOutputFlushScheduled = false
    private var isInputFeedbackPending = false
    private var markerParser = PortalMarkerParser()
    private var pendingBlockID: UUID?
    private var activeBlockID: UUID?
    private var activeBlockCwd: String?
    private var isReplayingCommand = false
    private var isReplayingHistoryOutput = false
    private var replayFallbackCommand: String?
    private var usesPagerScreenRendering = false
    private var didSeeAlternateScreenSwitch = false
    private var isAlternateScreenActive = false
    private var isApplicationCursorModeActive = false
    private var mouseTrackingMode: Ansi.MouseTrackingMode?
    private var usesSGRMouseMode = false

    init(flushDelay: DispatchTimeInterval = .milliseconds(33)) {
        self.flushDelay = flushDelay
    }

    func resetForCommand(blockID: UUID, cwd: String, usesPagerScreenRendering: Bool) {
        terminalResponseLock.withLock {
            pendingTerminalQuery = ""
            terminalQueryPosition = (1, 1)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingShellOutput.removeAll(keepingCapacity: true)
            self.isShellOutputFlushScheduled = false
            self.isInputFeedbackPending = false
            self.markerParser.reset()
            self.pendingBlockID = blockID
            self.activeBlockID = nil
            self.activeBlockCwd = cwd
            self.isReplayingCommand = false
            self.usesPagerScreenRendering = usesPagerScreenRendering
            self.didSeeAlternateScreenSwitch = false
            self.isAlternateScreenActive = false
            self.isApplicationCursorModeActive = false
            self.mouseTrackingMode = nil
            self.usesSGRMouseMode = false
            self.terminalScreen.resetForCommand()
            self.styledRenderer.reset()
        }
    }

    func resetForReplay(fallbackCommand: String? = nil) {
        terminalResponseLock.withLock {
            pendingTerminalQuery = ""
            terminalQueryPosition = (1, 1)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.resetForReplayOnQueue()
            self.replayFallbackCommand = fallbackCommand
        }
    }

    func replayShellOutput(_ text: String, completion: (() -> Void)? = nil) {
        terminalResponseLock.withLock {
            pendingTerminalQuery = ""
            terminalQueryPosition = (1, 1)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.isReplayingHistoryOutput = true
            self.resetForReplayOnQueue()
            self.consumeShellOutput(Self.replayText(text, fallbackCommand: self.replayFallbackCommand))
            self.replayFallbackCommand = nil
            self.isReplayingHistoryOutput = false
            self.flushPendingShellOutputOnQueue()
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func enqueueShellOutput(_ text: String) {
        for response in terminalResponses(in: text) {
            onTerminalResponse?(response)
        }
        queue.async { [weak self] in
            self?.enqueueShellOutputOnQueue(text)
        }
    }

    func prioritizeNextOutputForInput() {
        queue.async { [weak self] in
            self?.isInputFeedbackPending = true
        }
    }

    func flushAndFinish(_ completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushPendingShellOutputOnQueue()
            self.activeBlockID = nil
            self.activeBlockCwd = nil
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func resize(rows: Int, cols: Int) {
        terminalResponseLock.withLock { terminalQuerySize = (rows, cols) }
        queue.async { [weak self] in
            self?.terminalScreen.resize(rows: rows, cols: cols)
            self?.styledRenderer.resize(rows: rows)
        }
    }

    private func enqueueShellOutputOnQueue(_ text: String) {
        if isReplayingHistoryOutput {
            pendingShellOutput += text
            return
        }

        pendingShellOutput += text
        let delay = consumeInputFeedbackPriority() ? inputFeedbackFlushDelay : flushDelay
        guard !isShellOutputFlushScheduled else { return }

        isShellOutputFlushScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flushPendingShellOutputOnQueue()
        }
    }

    private func consumeInputFeedbackPriority() -> Bool {
        guard isInputFeedbackPending else { return false }
        isInputFeedbackPending = false
        return true
    }

    private func resetForReplayOnQueue() {
        pendingShellOutput.removeAll(keepingCapacity: true)
        isShellOutputFlushScheduled = false
        isInputFeedbackPending = false
        markerParser.reset()
        pendingBlockID = nil
        activeBlockID = nil
        activeBlockCwd = nil
        isReplayingCommand = false
        usesPagerScreenRendering = false
        didSeeAlternateScreenSwitch = false
        isAlternateScreenActive = false
        isApplicationCursorModeActive = false
        mouseTrackingMode = nil
        usesSGRMouseMode = false
        terminalScreen.resetForCommand()
        styledRenderer.reset()
    }

    private func flushPendingShellOutputOnQueue() {
        guard !pendingShellOutput.isEmpty else {
            isShellOutputFlushScheduled = false
            return
        }

        let text = pendingShellOutput
        pendingShellOutput.removeAll(keepingCapacity: true)
        isShellOutputFlushScheduled = false
        consumeShellOutput(text)
    }

    private func consumeShellOutput(_ text: String) {
        let events = markerParser.consume(text)
        let prioritizedCompletionIndex = isReplayingHistoryOutput ? nil : events.lastIndex {
            guard case .marker(let marker) = $0,
                  case .commandFinished = marker.kind
            else { return false }
            return true
        }
        if let prioritizedCompletionIndex,
           case .marker(let marker) = events[prioritizedCompletionIndex] {
            emit(.marker(marker, isReplay: false))
        }

        for (index, event) in events.enumerated() {
            switch event {
            case .text(let visible):
                flushVisible(visible)
            case .marker(let marker):
                if index != prioritizedCompletionIndex {
                    emit(.marker(marker, isReplay: isReplayingCommand))
                }
                if case .commandStarted(let command) = marker.kind {
                    if let pendingBlockID {
                        activeBlockID = pendingBlockID
                        self.pendingBlockID = nil
                        isReplayingCommand = false
                    } else {
                        let blockID = UUID()
                        terminalScreen.resetForCommand()
                        styledRenderer.reset()
                        isAlternateScreenActive = false
                        isApplicationCursorModeActive = false
                        mouseTrackingMode = nil
                        usesSGRMouseMode = false
                        activeBlockID = blockID
                        activeBlockCwd = nil
                        isReplayingCommand = true
                        emit(.replayCommandStarted(
                            blockID: blockID,
                            command: command
                        ))
                    }
                }
                if case .commandFinished = marker.kind {
                    activeBlockID = nil
                    pendingBlockID = nil
                    activeBlockCwd = nil
                    isReplayingCommand = false
                }
            }
        }
    }

    private func flushVisible(_ text: String) {
        guard !text.isEmpty, let activeBlockID else { return }
        consumeVisible(text, blockID: activeBlockID) { [weak self] snapshot in
            self?.emit(.snapshot(snapshot))
        }
    }

    private func consumeVisible(
        _ text: String,
        blockID: UUID,
        onSnapshot: (Snapshot) -> Void
    ) {
        let switches = Ansi.alternateScreenSwitchRanges(in: text)
        guard !switches.isEmpty else {
            consumeVisibleSegment(text, blockID: blockID, onSnapshot: onSnapshot)
            return
        }

        var cursor = text.startIndex
        for screenSwitch in switches {
            consumeVisibleSegment(
                String(text[cursor..<screenSwitch.range.lowerBound]),
                blockID: blockID,
                onSnapshot: onSnapshot
            )
            didSeeAlternateScreenSwitch = true
            consumeScreen(
                String(text[screenSwitch.range]),
                blockID: blockID,
                onSnapshot: onSnapshot
            )
            cursor = screenSwitch.range.upperBound
        }
        consumeVisibleSegment(String(text[cursor...]), blockID: blockID, onSnapshot: onSnapshot)
    }

    private func consumeVisibleSegment(
        _ text: String,
        blockID: UUID,
        onSnapshot: (Snapshot) -> Void
    ) {
        guard !text.isEmpty else { return }
        if isAlternateScreenActive || (usesPagerScreenRendering && !didSeeAlternateScreenSwitch) {
            consumeScreen(text, blockID: blockID, onSnapshot: onSnapshot)
        } else {
            let state = terminalScreen.process(text)
            isApplicationCursorModeActive = state.isApplicationCursorModeActive
            mouseTrackingMode = state.mouseTrackingMode
            usesSGRMouseMode = state.usesSGRMouseMode
            let rendered = styledRenderer.process(text, linkBaseDirectory: activeBlockCwd)
            onSnapshot(snapshot(
                blockID: blockID,
                plainText: rendered.plainText,
                attributedText: rendered.attributedText
            ))
        }
    }

    private func consumeScreen(
        _ text: String,
        blockID: UUID,
        onSnapshot: (Snapshot) -> Void
    ) {
        let state = terminalScreen.process(text, preservesAllRows: true)
        isAlternateScreenActive = state.isAlternateScreenActive
        isApplicationCursorModeActive = state.isApplicationCursorModeActive
        mouseTrackingMode = state.mouseTrackingMode
        usesSGRMouseMode = state.usesSGRMouseMode
        if state.isAlternateScreenActive || (usesPagerScreenRendering && !didSeeAlternateScreenSwitch) {
            onSnapshot(snapshot(
                blockID: blockID,
                plainText: state.text,
                attributedText: state.attributedText
            ))
        } else {
            let rendered = styledRenderer.process("", linkBaseDirectory: activeBlockCwd)
            onSnapshot(snapshot(
                blockID: blockID,
                plainText: rendered.plainText,
                attributedText: rendered.attributedText
            ))
        }
    }

    private func snapshot(
        blockID: UUID,
        plainText: String,
        attributedText: NSAttributedString
    ) -> Snapshot {
        Snapshot(
            blockID: blockID,
            plainText: plainText,
            attributedText: attributedText,
            isAlternateScreenActive: isAlternateScreenActive,
            isApplicationCursorModeActive: isApplicationCursorModeActive,
            mouseTrackingMode: mouseTrackingMode,
            usesSGRMouseMode: usesSGRMouseMode
        )
    }

    static func alternateScreenTranscriptSelfTest() -> Bool {
        func finalSnapshot(for text: String) -> Snapshot? {
            let processor = TerminalOutputProcessor()
            let blockID = UUID()
            var last: Snapshot?
            processor.consumeVisible(text, blockID: blockID) { snapshot in
                last = snapshot
            }
            return last
        }

        return finalSnapshot(for: "before\n\u{1B}[?1049heditor text\u{1B}[?1049lafter\n")?.plainText == "before\nafter\n"
            && finalSnapshot(for: "\u{1B}[?1049heditor text\u{1B}[?1049l")?.plainText == ""
            && finalSnapshot(for: "\u{1B}[?1h\u{1B}=\u{1B}[?1049hpager")?.isApplicationCursorModeActive == true
            && finalSnapshot(for: "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1006hmouse")?.mouseTrackingMode == .button
            && finalSnapshot(for: "\u{1B}[?1003h\u{1B}[?1006hmouse")?.usesSGRMouseMode == true
    }

    static func terminalSizeProbeSelfTest() -> Bool {
        TerminalOutputProcessor().terminalResponses(in: "\u{1B}[999;999f\u{1B}[6n")
            .contains("\u{1B}[30;100R")
    }

    static func terminalResponsesAreImmediateSelfTest() -> Bool {
        let processor = TerminalOutputProcessor(flushDelay: .seconds(1))
        var responses: [String] = []
        processor.onTerminalResponse = { responses.append($0) }
        let unblockRenderer = DispatchSemaphore(value: 0)
        processor.queue.async { unblockRenderer.wait() }
        processor.enqueueShellOutput("\u{1B}]11;?")
        processor.enqueueShellOutput("\u{7}\u{1B}[6n")
        let liveResponsesAreImmediate = responses == [
            "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\",
            "\u{1B}[1;1R",
        ]
        unblockRenderer.signal()
        processor.queue.sync {}
        // Repeated queries are distinct requests, even within one render batch.
        processor.enqueueShellOutput("\u{1B}[6n\u{1B}[6n")
        let repeatedQueriesAreAnswered = responses.count == 4
        let replayProcessor = TerminalOutputProcessor()
        replayProcessor.onTerminalResponse = { _ in responses.append("replay") }
        replayProcessor.replayShellOutput("\u{1B}]11;?\u{7}\u{1B}[6n")
        let replayIsSilent = replayProcessor.queue.sync { !responses.contains("replay") }
        return liveResponsesAreImmediate && repeatedQueriesAreAnswered && replayIsSilent
    }

    static func inputFeedbackPrioritySelfTest() -> Bool {
        let processor = TerminalOutputProcessor()
        return processor.queue.sync {
            processor.isInputFeedbackPending = true
            processor.enqueueShellOutputOnQueue("\u{1B}[41;130H~@k")
            guard processor.pendingShellOutput.hasSuffix("~@k") else { return false }
            processor.enqueueShellOutputOnQueue("\u{1B}[41;130H   ")
            return processor.pendingShellOutput.hasSuffix("~@k\u{1B}[41;130H   ")
        }
    }

    static func truncatedHistoryReplaySelfTest() -> Bool {
        let finish = "output\u{1B}]133;P;L3RtcA==\u{7}\u{1B}]133;D;0\u{7}"
        let restored = replayText(finish, fallbackCommand: "make release")
        let existing = "\u{1B}]133;C;bWFrZSByZWxlYXNl\u{7}" + finish
        let startup = "export PORTAL=1\r\nPROMPT=''\r\n\u{1B}]133;R;L3RtcA==\u{7}"
        return restored.hasPrefix("\u{1B}]133;C;bWFrZSByZWxlYXNl\u{7}")
            && replayText(existing, fallbackCommand: "make release") == existing
            && replayText("", fallbackCommand: "make release").isEmpty
            && replayText(startup, fallbackCommand: "p") == startup
            && replayText(startup + existing, fallbackCommand: "p") == startup + existing
    }

    private static func replayText(_ text: String, fallbackCommand: String?) -> String {
        let text = TerminalHistory.normalizedReplay(text)
        // A retained shell-ready marker identifies startup output, not a truncated command.
        guard !text.isEmpty,
              !text.contains("\u{1B}]133;R;"),
              !text.contains("\u{1B}]133;C;"),
              let fallbackCommand
        else { return text }
        return "\u{1B}]133;C;\(Data(fallbackCommand.utf8).base64EncodedString())\u{7}" + text
    }

    private func emit(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event)
        }
    }

    private func terminalResponses(in text: String) -> [String] {
        terminalResponseLock.withLock {
            let queries = ["\u{1B}]10;?\u{7}", "\u{1B}]10;?\u{1B}\\",
                           "\u{1B}]11;?\u{7}", "\u{1B}]11;?\u{1B}\\",
                           "\u{1B}[6n", "\u{1B}[999;999f", "\u{1B}[999;999H"]
            var responses: [String] = []
            for scalar in text.unicodeScalars {
                if pendingTerminalQuery.isEmpty && scalar.value != 0x1b { continue }
                pendingTerminalQuery.unicodeScalars.append(scalar)
                if queries.contains(pendingTerminalQuery) {
                    switch pendingTerminalQuery {
                    case "\u{1B}[999;999f", "\u{1B}[999;999H":
                        terminalQueryPosition = terminalQuerySize
                    case "\u{1B}[6n":
                        responses.append("\u{1B}[\(terminalQueryPosition.0);\(terminalQueryPosition.1)R")
                        terminalQueryPosition = (1, 1)
                    default:
                        let foreground = pendingTerminalQuery.hasPrefix("\u{1B}]10;")
                        responses.append(foreground
                            ? "\u{1B}]10;rgb:ffff/ffff/ffff\u{1B}\\"
                            : "\u{1B}]11;rgb:0000/0000/0000\u{1B}\\")
                    }
                    pendingTerminalQuery = ""
                } else if !queries.contains(where: { $0.hasPrefix(pendingTerminalQuery) }) {
                    pendingTerminalQuery = scalar.value == 0x1b ? "\u{1B}" : ""
                }
            }
            return responses
        }
    }
}


#endif
