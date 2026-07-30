import Foundation
import Testing
@testable import VaulttyCore

@Suite("Command lifecycle")
struct CommandLifecycleTests {
    @Test("submission and completion share one transition path")
    func submissionAndCompletion() throws {
        let lifecycle = CommandLifecycle(cwd: "/repo")
        let startedAt = Date(timeIntervalSince1970: 100)

        let submission = lifecycle.apply(.submit(command: "cargo test", cwd: "/repo", at: startedAt))
        let blockID = try #require(submission.addedBlockIDs.first)
        #expect(lifecycle.state.pendingBlockID == blockID)
        #expect(lifecycle.state.commandHistory == ["cargo test"])
        #expect(lifecycle.state.commandCount == 1)
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

    @Test("history replay never enables input while a command remains active")
    func replayKeepsInputDisabledForRunningCommand() {
        let lifecycle = CommandLifecycle(cwd: "/repo", commandCount: 2)
        lifecycle.apply(.beginHistoryReplay)
        lifecycle.apply(.replayCommandStarted(
            blockID: UUID(),
            command: "make",
            at: Date(timeIntervalSince1970: 100)
        ))

        lifecycle.apply(.finishHistoryReplay)

        #expect(lifecycle.state.isCommandRunning)
        #expect(!lifecycle.state.isShellReady)
        #expect(!lifecycle.state.isReplayingHistory)
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

        lifecycle.apply(.replaceSession(cwd: "/new", commandCount: 4, commandHistory: ["new"]))

        #expect(lifecycle.state.blocks.isEmpty)
        #expect(lifecycle.state.currentCwd == "/new")
        #expect(lifecycle.state.commandCount == 4)
        #expect(lifecycle.state.commandHistory == ["new"])
        #expect(!lifecycle.state.isShellReady)
        #expect(!lifecycle.state.hasExited)
        #expect(!lifecycle.state.needsShellInputResetBeforeNextSubmit)
    }
}
