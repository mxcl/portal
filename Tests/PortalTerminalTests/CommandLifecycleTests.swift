#if os(macOS)
import Foundation
import Testing
@testable import PortalTerminal

@Suite("Command lifecycle")
struct CommandLifecycleTests {
    @Test func commandRunDatesSurviveRestorationAndUpdateOnRepeat() throws {
        let oldDate = Date(timeIntervalSince1970: 10)
        let newDate = Date(timeIntervalSince1970: 30)
        let lifecycle = CommandLifecycle(cwd: "/repo", commandHistory: ["deploy"], commandRunDates: ["deploy": oldDate])
        lifecycle.apply(.submit(command: "test", cwd: "/repo", at: Date(timeIntervalSince1970: 20)))
        lifecycle.apply(.commandFinished(status: 0, isReplay: false, at: Date(timeIntervalSince1970: 25)))
        lifecycle.apply(.submit(command: "deploy", cwd: "/repo", at: newDate))
        #expect(lifecycle.state.commandHistory == ["test", "deploy"])
        #expect(lifecycle.state.commandRunDates["deploy"] == newDate)
        let record = SessionCatalog.Record(sessionID: "test", title: "test", cwd: "/repo",
            commandHistory: lifecycle.state.commandHistory, commandRunDates: lifecycle.state.commandRunDates)
        let restored = try JSONDecoder().decode(SessionCatalog.Record.self, from: JSONEncoder().encode(record))
        #expect(restored.commandRunDates == lifecycle.state.commandRunDates)
        lifecycle.apply(.replaceSession(cwd: "/other", commandCount: 0, lastCommandAt: nil, commandHistory: []))
        #expect(lifecycle.state.commandRunDates.isEmpty)
        let legacy = try JSONDecoder().decode(SessionCatalog.Record.self,
            from: Data(#"{"sessionID":"old","title":"old","cwd":"/repo","commandHistory":["deploy"]}"#.utf8))
        #expect(legacy.commandRunDates == nil)
    }

    @Test("submission and completion share one transition path")
    func submissionAndCompletion() throws {
        let lifecycle = CommandLifecycle(cwd: "/repo")
        let startedAt = Date(timeIntervalSince1970: 100)

        let submission = lifecycle.apply(.submit(command: "cargo test", cwd: "/repo", at: startedAt))
        let blockID = try #require(submission.addedBlockIDs.first)
        #expect(lifecycle.state.pendingBlockID == blockID)
        #expect(lifecycle.state.commandHistory == ["cargo test"])
        #expect(lifecycle.state.commandCount == 1)
        #expect(lifecycle.state.lastCommandAt == startedAt)
        #expect(!lifecycle.state.isShellReady)

        lifecycle.apply(.commandStarted)
        #expect(lifecycle.state.activeBlockID == blockID)

        let finishedAt = Date(timeIntervalSince1970: 105)
        let completion = lifecycle.apply(.commandFinished(status: 7, isReplay: false, at: finishedAt))
        #expect(completion.finishedBlockIDs == [blockID])
        #expect(lifecycle.state.activeBlockID == nil)
        #expect(lifecycle.state.isShellReady)
        let block = try #require(lifecycle.state.blocks.first)
        #expect(block.finishedAt == finishedAt)
        guard case .completed(let status) = block.state else {
            Issue.record("Expected completed block")
            return
        }
        #expect(status == 7)
    }

    @Test("completion recovers when the command-start marker is missed")
    func completionWithoutCommandStart() throws {
        let lifecycle = CommandLifecycle(cwd: "/repo")
        let submission = lifecycle.apply(.submit(command: "git status", cwd: "/repo", at: .now))
        let blockID = try #require(submission.addedBlockIDs.first)

        let completion = lifecycle.apply(.commandFinished(status: 0, isReplay: false, at: .now))

        #expect(completion.finishedBlockIDs == [blockID])
        #expect(!lifecycle.state.isCommandRunning)
        #expect(lifecycle.state.isShellReady)
    }

    @Test("a new session waits for shell setup after its initial history page")
    func initialHistoryDoesNotFinishShellSetup() {
        let lifecycle = CommandLifecycle(cwd: "/tmp")
        // READY(created: true) starts setup; v2 immediately follows with HISTORY_PAGE.
        lifecycle.apply(.beginShellInitialization)
        lifecycle.apply(.beginHistoryReplay)
        lifecycle.apply(.finishHistoryReplay)
        #expect(!lifecycle.state.isShellReady)
        lifecycle.apply(.shellReady(cwd: "/tmp"))
        #expect(lifecycle.state.isShellReady)
    }

    @Test("history replay never enables input while a command remains active")
    func replayKeepsInputDisabledForRunningCommand() {
        let lifecycle = CommandLifecycle(cwd: "/repo", commandCount: 2)
        lifecycle.apply(.beginHistoryReplay)
        lifecycle.apply(.replayCommandStarted(
            blockID: UUID(),
            command: "make",
            at: Date(timeIntervalSince1970: 100)
        ))
        #expect(lifecycle.state.lastCommandAt == nil)

        lifecycle.apply(.finishHistoryReplay)

        #expect(lifecycle.state.isCommandRunning)
        #expect(!lifecycle.state.isShellReady)
        #expect(!lifecycle.state.isReplayingHistory)
    }

    @Test("reconnection replaces history instead of appending duplicate blocks")
    func reconnectReplacesHistory() {
        let lifecycle = CommandLifecycle(cwd: "/repo", commandCount: 1)
        for _ in 0..<2 {
            lifecycle.apply(.beginHistoryReplay)
            lifecycle.apply(.replayCommandStarted(blockID: UUID(), command: "printf hello", at: .now))
            lifecycle.apply(.commandFinished(status: 0, isReplay: true, at: .now))
            lifecycle.apply(.finishHistoryReplay)
            #expect(lifecycle.state.blocks.count == 1)
            #expect(lifecycle.state.commandCount == 1)
            #expect(lifecycle.state.isShellReady)
        }
    }

    @Test("a newly received command updates recency")
    func receivedCommandUpdatesRecency() {
        let lifecycle = CommandLifecycle(cwd: "/repo", commandCount: 2)
        let receivedAt = Date(timeIntervalSince1970: 100)

        lifecycle.apply(.replayCommandStarted(
            blockID: UUID(),
            command: "make",
            at: receivedAt
        ))

        #expect(lifecycle.state.lastCommandAt == receivedAt)
    }

    @Test("interrupt waits for the shell to report completion")
    func interruptWaitsForShellCompletion() throws {
        let lifecycle = CommandLifecycle(cwd: "/repo")
        let submission = lifecycle.apply(.submit(command: "less file", cwd: "/repo", at: .now))
        let blockID = try #require(submission.addedBlockIDs.first)
        lifecycle.apply(.commandStarted)
        lifecycle.apply(.output(
            blockID: blockID,
            plainText: "page",
            attributedText: NSAttributedString(string: "page"),
            isAlternateScreenActive: true,
            isApplicationCursorModeActive: true
        ))

        let change = lifecycle.apply(.interruptRequested)

        #expect(change.finishedBlockIDs.isEmpty)
        #expect(lifecycle.state.activeBlockID == blockID)
        #expect(lifecycle.state.isCommandRunning)
        #expect(!lifecycle.state.isShellReady)
        #expect(lifecycle.state.isAlternateScreenActive)
        #expect(lifecycle.state.isApplicationCursorModeActive)
    }

    @Test("shell exit wins over replay and readiness")
    func shellExitWins() {
        let lifecycle = CommandLifecycle(cwd: "/repo")
        lifecycle.apply(.beginHistoryReplay)
        lifecycle.apply(.shellReady(cwd: "/other"))
        lifecycle.apply(.shellExited(status: 0, at: .now))
        lifecycle.apply(.finishHistoryReplay)

        #expect(lifecycle.state.currentCwd == "/other")
        #expect(lifecycle.state.hasExited)
        #expect(!lifecycle.state.isReplayingHistory)
        #expect(!lifecycle.state.isShellReady)
    }

    @Test("history navigation preserves and restores the draft")
    func historyNavigation() {
        let lifecycle = CommandLifecycle(
            cwd: "/repo",
            commandCount: 2,
            commandHistory: ["first", "second"]
        )
        lifecycle.apply(.shellReady(cwd: nil))

        #expect(lifecycle.apply(.previousHistory(draft: "draft")).selectedHistoryInput == "second")
        #expect(lifecycle.apply(.previousHistory(draft: "ignored")).selectedHistoryInput == "first")
        #expect(lifecycle.apply(.nextHistory).selectedHistoryInput == "second")
        #expect(lifecycle.apply(.nextHistory).selectedHistoryInput == "draft")
    }

    @Test("replacing a session resets every command invariant")
    func replaceSession() {
        let lifecycle = CommandLifecycle(cwd: "/old")
        lifecycle.apply(.shellReady(cwd: nil))
        lifecycle.apply(.submit(command: "echo old", cwd: "/old", at: .now))
        lifecycle.apply(.markNeedsShellInputReset)

        let lastCommandAt = Date(timeIntervalSince1970: 200)
        lifecycle.apply(.replaceSession(
            cwd: "/new",
            commandCount: 4,
            lastCommandAt: lastCommandAt,
            commandHistory: ["new"]
        ))

        #expect(lifecycle.state.blocks.isEmpty)
        #expect(lifecycle.state.currentCwd == "/new")
        #expect(lifecycle.state.commandCount == 4)
        #expect(lifecycle.state.lastCommandAt == lastCommandAt)
        #expect(lifecycle.state.commandHistory == ["new"])
        #expect(!lifecycle.state.isShellReady)
        #expect(!lifecycle.state.hasExited)
        #expect(!lifecycle.state.needsShellInputResetBeforeNextSubmit)
    }
}

#endif
