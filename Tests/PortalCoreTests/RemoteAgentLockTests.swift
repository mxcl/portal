#if os(macOS)
import Foundation
import Testing
@testable import PortalCore

private actor LockContentionSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Remote agent lock")
struct RemoteAgentLockTests {
    @Test("replacement waits for the previous agent to release its lock")
    func replacementWaitsForLockHandoff() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("portal-remote-agent-lock-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let current = try #require(RemoteAgentLock.acquire(path: path, waitingUpTo: 0))
        let contention = LockContentionSignal()
        let replacement = Task.detached {
            RemoteAgentLock.acquire(
                path: path,
                waitingUpTo: 1,
                onContention: { Task { await contention.signal() } }
            )
        }

        await contention.wait()
        current.release()

        let acquired = await replacement.value
        #expect(acquired != nil)
        acquired?.release()
    }

    @Test("replacement stops waiting after the handoff deadline")
    func replacementTimesOut() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("portal-remote-agent-lock-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let current = try #require(RemoteAgentLock.acquire(path: path, waitingUpTo: 0))
        defer { current.release() }

        let replacement = await Task.detached {
            RemoteAgentLock.acquire(
                path: path,
                waitingUpTo: 0.02,
                retryMicroseconds: 1_000
            )
        }.value

        #expect(replacement == nil)
    }
}
#endif
