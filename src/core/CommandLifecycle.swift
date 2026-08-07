import Foundation

final class CommandLifecycle {
    struct Block {
        enum State {
            case running
            case completed(Int32)
        }

        let id: UUID
        let command: String
        let cwd: String
        let startedAt: Date
        var finishedAt: Date?
        var output: String
        var attributedOutput: NSAttributedString
        var outputRevision: Int
        var state: State
    }

    struct State {
        fileprivate(set) var blocks: [Block]
        fileprivate(set) var activeBlockID: UUID?
        fileprivate(set) var pendingBlockID: UUID?
        fileprivate(set) var currentCwd: String
        fileprivate(set) var isShellReady: Bool
        fileprivate(set) var isReplayingHistory: Bool
        fileprivate(set) var needsShellInputResetBeforeNextSubmit: Bool
        fileprivate(set) var hasExited: Bool
        fileprivate(set) var isAlternateScreenActive: Bool
        fileprivate(set) var isApplicationCursorModeActive: Bool
        fileprivate(set) var commandHistory: [String]
        fileprivate(set) var commandHistoryIndex: Int?
        fileprivate(set) var commandHistoryDraft: String
        fileprivate(set) var commandCount: Int
        fileprivate(set) var lastCommandAt: Date?

        var isCommandRunning: Bool {
            guard let latest = blocks.last else { return false }
            if activeBlockID == latest.id || pendingBlockID == latest.id {
                return true
            }
            if case .running = latest.state {
                return true
            }
            return false
        }

        var latestRunningBlock: Block? {
            isCommandRunning ? blocks.last : nil
        }
    }

    enum Event {
        case replaceSession(cwd: String, commandCount: Int, lastCommandAt: Date?, commandHistory: [String])
        case resetTranscript
        case clearTranscript(keeping: Set<UUID>)
        case beginHistoryReplay
        case finishHistoryReplay
        case markNeedsShellInputReset
        case consumeShellInputReset
        case submit(command: String, cwd: String, at: Date)
        case submitEmpty(cwd: String, at: Date)
        case interruptRequested
        case replayCommandStarted(blockID: UUID, command: String, at: Date)
        case output(
            blockID: UUID,
            plainText: String,
            attributedText: NSAttributedString,
            isAlternateScreenActive: Bool,
            isApplicationCursorModeActive: Bool
        )
        case shellReady(cwd: String?)
        case cwdChanged(String)
        case commandStarted
        case commandFinished(status: Int32, isReplay: Bool, at: Date)
        case shellExited(status: Int32, at: Date)
        case previousHistory(draft: String)
        case nextHistory
        case resetHistorySelection
    }

    struct Change {
        fileprivate(set) var addedBlockIDs: [UUID] = []
        fileprivate(set) var updatedBlockIDs: [UUID] = []
        fileprivate(set) var finishedBlockIDs: [UUID] = []
        fileprivate(set) var removedBlockIDs: [UUID] = []
        fileprivate(set) var selectedHistoryInput: String?
        fileprivate(set) var didChangeTerminalMode = false
        fileprivate(set) var didConsumeShellInputReset = false
    }

    private(set) var state: State

    init(
        cwd: String,
        commandCount: Int = 0,
        lastCommandAt: Date? = nil,
        commandHistory: [String] = []
    ) {
        state = State(
            blocks: [],
            activeBlockID: nil,
            pendingBlockID: nil,
            currentCwd: cwd,
            isShellReady: false,
            isReplayingHistory: false,
            needsShellInputResetBeforeNextSubmit: false,
            hasExited: false,
            isAlternateScreenActive: false,
            isApplicationCursorModeActive: false,
            commandHistory: commandHistory,
            commandHistoryIndex: nil,
            commandHistoryDraft: "",
            commandCount: commandCount,
            lastCommandAt: lastCommandAt
        )
    }

    @discardableResult
    func apply(_ event: Event) -> Change {
        var change = Change()
        switch event {
        case .replaceSession(let cwd, let commandCount, let lastCommandAt, let commandHistory):
            let removedIDs = state.blocks.map(\.id)
            state.blocks.removeAll()
            state.activeBlockID = nil
            state.pendingBlockID = nil
            state.currentCwd = cwd
            state.isShellReady = false
            state.isReplayingHistory = false
            state.needsShellInputResetBeforeNextSubmit = false
            state.hasExited = false
            state.isAlternateScreenActive = false
            state.isApplicationCursorModeActive = false
            state.commandHistory = commandHistory
            state.commandHistoryIndex = nil
            state.commandHistoryDraft = ""
            state.commandCount = commandCount
            state.lastCommandAt = lastCommandAt
            change.removedBlockIDs = removedIDs

        case .resetTranscript:
            change.removedBlockIDs = state.blocks.map(\.id)
            state.blocks.removeAll()
            state.activeBlockID = nil
            state.pendingBlockID = nil

        case .clearTranscript(let keeping):
            let removed = state.blocks.filter { !keeping.contains($0.id) }.map(\.id)
            state.blocks.removeAll { !keeping.contains($0.id) }
            if state.activeBlockID.map(keeping.contains) != true { state.activeBlockID = nil }
            if state.pendingBlockID.map(keeping.contains) != true { state.pendingBlockID = nil }
            state.commandHistoryIndex = nil
            state.commandHistoryDraft = ""
            change.removedBlockIDs = removed

        case .beginHistoryReplay:
            state.isReplayingHistory = true
            state.isShellReady = false

        case .finishHistoryReplay:
            state.isReplayingHistory = false
            if !state.hasExited && !state.isCommandRunning {
                state.isShellReady = true
            }

        case .markNeedsShellInputReset:
            state.needsShellInputResetBeforeNextSubmit = true

        case .consumeShellInputReset:
            change.didConsumeShellInputReset = state.needsShellInputResetBeforeNextSubmit
            state.needsShellInputResetBeforeNextSubmit = false

        case .submit(let command, let cwd, let timestamp):
            if let previousIndex = state.commandHistory.firstIndex(of: command) {
                state.commandHistory.remove(at: previousIndex)
            }
            state.commandCount += 1
            state.lastCommandAt = timestamp
            state.commandHistory.append(command)
            state.commandHistoryIndex = nil
            state.commandHistoryDraft = ""
            state.isShellReady = false
            resetTerminalModes(change: &change)
            let block = Block(
                id: UUID(),
                command: command,
                cwd: cwd,
                startedAt: timestamp,
                finishedAt: nil,
                output: "",
                attributedOutput: NSAttributedString(),
                outputRevision: 0,
                state: .running
            )
            state.blocks.append(block)
            state.pendingBlockID = block.id
            change.addedBlockIDs = [block.id]

        case .submitEmpty(let cwd, let timestamp):
            state.commandHistoryIndex = nil
            state.commandHistoryDraft = ""
            let block = Block(
                id: UUID(),
                command: "",
                cwd: cwd,
                startedAt: timestamp,
                finishedAt: timestamp,
                output: "",
                attributedOutput: NSAttributedString(),
                outputRevision: 0,
                state: .completed(0)
            )
            state.blocks.append(block)
            change.addedBlockIDs = [block.id]

        case .interruptRequested:
            break

        case .replayCommandStarted(let blockID, let command, let timestamp):
            guard !state.blocks.contains(where: { $0.id == blockID }) else { break }
            change.finishedBlockIDs = finishRunningBlocks(status: 0, at: timestamp)
            let block = Block(
                id: blockID,
                command: command,
                cwd: state.currentCwd,
                startedAt: timestamp,
                finishedAt: nil,
                output: "",
                attributedOutput: NSAttributedString(),
                outputRevision: 0,
                state: .running
            )
            state.blocks.append(block)
            if !command.isEmpty {
                state.commandCount = max(state.commandCount, state.blocks.filter { !$0.command.isEmpty }.count)
                if !state.isReplayingHistory {
                    state.lastCommandAt = timestamp
                }
            }
            state.activeBlockID = blockID
            state.pendingBlockID = nil
            change.addedBlockIDs = [blockID]

        case .output(
            let blockID,
            let plainText,
            let attributedText,
            let alternateScreen,
            let applicationCursorMode
        ):
            guard let index = state.blocks.firstIndex(where: { $0.id == blockID }) else { break }
            change.didChangeTerminalMode = state.isAlternateScreenActive != alternateScreen
                || state.isApplicationCursorModeActive != applicationCursorMode
            state.isAlternateScreenActive = alternateScreen
            state.isApplicationCursorModeActive = applicationCursorMode
            state.blocks[index].output = plainText
            state.blocks[index].attributedOutput = attributedText
            state.blocks[index].outputRevision += 1
            change.updatedBlockIDs = [blockID]

        case .shellReady(let cwd):
            if let cwd { state.currentCwd = cwd }
            if !state.isReplayingHistory && !state.hasExited {
                state.isShellReady = true
            }

        case .cwdChanged(let cwd):
            state.currentCwd = cwd

        case .commandStarted:
            if let pendingBlockID = state.pendingBlockID {
                state.activeBlockID = pendingBlockID
                state.pendingBlockID = nil
            }

        case .commandFinished(let status, let isReplay, let timestamp):
            if let blockID = state.activeBlockID ?? state.pendingBlockID,
               let index = state.blocks.firstIndex(where: { $0.id == blockID }) {
                state.blocks[index].finishedAt = isReplay ? nil : timestamp
                state.blocks[index].state = .completed(status)
                change.finishedBlockIDs = [blockID]
            }
            state.activeBlockID = nil
            state.pendingBlockID = nil
            resetTerminalModes(change: &change)
            if !state.isReplayingHistory && !state.hasExited {
                state.isShellReady = true
            }

        case .shellExited(let status, let timestamp):
            state.hasExited = true
            state.isReplayingHistory = false
            state.isShellReady = false
            change.finishedBlockIDs = finishRunningBlocks(status: status, at: timestamp)
            resetTerminalModes(change: &change)

        case .previousHistory(let draft):
            guard state.isShellReady, !state.isReplayingHistory, !state.commandHistory.isEmpty else { break }
            let nextIndex: Int
            if let index = state.commandHistoryIndex {
                nextIndex = max(0, index - 1)
            } else {
                state.commandHistoryDraft = draft
                nextIndex = state.commandHistory.count - 1
            }
            state.commandHistoryIndex = nextIndex
            change.selectedHistoryInput = state.commandHistory[nextIndex]

        case .nextHistory:
            guard state.isShellReady,
                  !state.isReplayingHistory,
                  let index = state.commandHistoryIndex
            else { break }
            let nextIndex = index + 1
            if nextIndex < state.commandHistory.count {
                state.commandHistoryIndex = nextIndex
                change.selectedHistoryInput = state.commandHistory[nextIndex]
            } else {
                state.commandHistoryIndex = nil
                change.selectedHistoryInput = state.commandHistoryDraft
                state.commandHistoryDraft = ""
            }

        case .resetHistorySelection:
            state.commandHistoryIndex = nil
            state.commandHistoryDraft = ""
        }
        return change
    }

    private func finishRunningBlocks(status: Int32, at timestamp: Date) -> [UUID] {
        var finishedIDs: [UUID] = []
        for index in state.blocks.indices {
            if case .running = state.blocks[index].state {
                state.blocks[index].finishedAt = timestamp
                state.blocks[index].state = .completed(status)
                finishedIDs.append(state.blocks[index].id)
            }
        }
        state.activeBlockID = nil
        state.pendingBlockID = nil
        return finishedIDs
    }

    private func resetTerminalModes(change: inout Change) {
        change.didChangeTerminalMode = state.isAlternateScreenActive || state.isApplicationCursorModeActive
        state.isAlternateScreenActive = false
        state.isApplicationCursorModeActive = false
    }
}
