import Foundation
import Testing
@testable import VaulttyCore

private actor LocalLoadSequence {
    private var values: [[SessionPickerCandidate]?]

    init(_ values: [[SessionPickerCandidate]?]) {
        self.values = values
    }

    func next() -> [SessionPickerCandidate]? {
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }
}

private actor RelayLoadSequence {
    private var values: [[SessionPickerCandidate]?]
    private var loadCount = 0

    init(_ values: [[SessionPickerCandidate]?]) {
        self.values = values
    }

    func next() -> [SessionPickerCandidate]? {
        loadCount += 1
        guard !values.isEmpty else { return nil }
        return values.removeFirst()
    }

    func count() -> Int {
        loadCount
    }
}

private actor RelayDelayGate {
    private var callCount = 0
    private var delayWaiters: [CheckedContinuation<Void, Never>] = []
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func delay() async {
        callCount += 1
        let ready = countWaiters.filter { callCount >= $0.0 }
        countWaiters.removeAll { callCount >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { delayWaiters.append($0) }
    }

    func waitForCall(_ target: Int) async {
        guard callCount < target else { return }
        await withCheckedContinuation { countWaiters.append((target, $0)) }
    }

    func advance() {
        guard !delayWaiters.isEmpty else { return }
        delayWaiters.removeFirst().resume()
    }
}

private actor AsyncSignal {
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

@Suite("Session picker model")
struct SessionPickerModelTests {
    @Test("only detached or closed sessions can be exited")
    func exitEligibility() {
        let visible = candidate(id: "visible", host: "This Mac", date: 1, location: .local)
        var closed = visible
        closed.isClosed = true
        var detached = visible
        detached.attachedClientCount = 0
        var attached = visible
        attached.attachedClientCount = 1
        var create = detached
        create.action = .createRelay

        #expect(!visible.canExit)
        #expect(closed.canExit)
        #expect(detached.canExit)
        #expect(!attached.canExit)
        #expect(!create.canExit)
    }

    @MainActor
    @Test("loads relay sessions")
    func loadsRelaySessions() async throws {
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []

        model.refresh(
            initial: [],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { [] },
            loadRelay: {
                [candidate(
                    id: "new-relay-session",
                    host: "Pangolin",
                    date: 0,
                    location: .relayMac("pangolin-relay"),
                    action: .createRelay
                )]
            },
            isAvailable: { _ in true },
            onUpdate: { snapshots.append($0) }
        )

        try await Task.sleep(nanoseconds: 10_000_000)

        let final = try #require(snapshots.last)
        #expect(final.sections.count == 1)
        #expect(final.sections[0].items.isEmpty)
        #expect(final.sections[0].newSession?.action == .createRelay)
        model.invalidate()
    }

    @MainActor
    @Test("deduplicates, groups, sorts, and rejects stale loads")
    func progressiveSnapshots() async throws {
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []
        let oldRemote = candidate(id: "old", host: "Zulu", date: 1)
        let local = candidate(id: "local", host: "This Mac", date: 2, location: .local)

        model.refresh(
            initial: [local],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { [local] },
            loadRelay: {
                try? await Task.sleep(nanoseconds: 20_000_000)
                return [oldRemote]
            },
            isAvailable: { _ in true },
            onUpdate: { snapshots.append($0) }
        )
        model.refresh(
            initial: [local],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { [local] },
            loadRelay: {
                [oldRemote, oldRemote, candidate(id: "alpha", host: "Alpha", date: 3)]
            },
            isAvailable: { _ in true },
            onUpdate: { snapshots.append($0) }
        )

        try await Task.sleep(nanoseconds: 40_000_000)

        let final = try #require(snapshots.last)
        #expect(final.sections.map(\.title) == ["Alpha", "Zulu", "This Mac"])
        #expect(final.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "alpha", "old", "local"
        ])
        #expect(final.sections.flatMap(\.items).filter {
            $0.candidate.sessionRef.sessionID == "old"
        }.count == 1)
        #expect(final.sections.flatMap(\.items).allSatisfy { $0.metadata.contains(" old · ") })
        model.invalidate()
    }

    @MainActor
    @Test("retries failed local inventory while picker remains visible")
    func retriesLocalInventory() async throws {
        let recovered = candidate(id: "recovered", host: "This Mac", date: 1, location: .local)
        let loads = LocalLoadSequence([nil, [recovered]])
        let recoveredUpdate = AsyncSignal()
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []

        model.refresh(
            initial: [],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { await loads.next() },
            loadRelay: { [] },
            isAvailable: { _ in true },
            onUpdate: {
                snapshots.append($0)
                if $0.sections.flatMap(\.items).contains(where: {
                    $0.candidate.sessionRef.sessionID == "recovered"
                }) {
                    Task { await recoveredUpdate.signal() }
                }
            }
        )

        await recoveredUpdate.wait()

        #expect(snapshots.last?.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "recovered"
        ])
        model.invalidate()
    }

    @MainActor
    @Test("successful local inventory removes missing persisted local sessions")
    func localInventoryRemovesPersistedGhosts() async throws {
        let local = candidate(id: "local-ghost", host: "This Mac", date: 2, location: .local)
        let relay = candidate(
            id: "relay-last-good",
            host: "Pangolin",
            date: 1,
            location: .relayMac("pangolin")
        )
        let updated = AsyncSignal()
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []

        model.refresh(
            initial: [local, relay],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { [] },
            loadRelay: {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            },
            isAvailable: { _ in true },
            onUpdate: {
                snapshots.append($0)
                if snapshots.count == 2 {
                    Task { await updated.signal() }
                }
            }
        )

        await updated.wait()
        model.invalidate()

        #expect(snapshots.last?.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "relay-last-good"
        ])
    }

    @MainActor
    @Test("successful relay inventory removes missing persisted relay sessions")
    func relayInventoryRemovesPersistedGhosts() async throws {
        let local = candidate(id: "local-last-good", host: "This Mac", date: 2, location: .local)
        let relay = candidate(
            id: "relay-ghost",
            host: "Pangolin",
            date: 1,
            location: .relayMac("pangolin")
        )
        let updated = AsyncSignal()
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []

        model.refresh(
            initial: [local, relay],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            },
            loadRelay: { [] },
            isAvailable: { _ in true },
            onUpdate: {
                snapshots.append($0)
                if snapshots.count == 2 {
                    Task { await updated.signal() }
                }
            }
        )

        await updated.wait()
        model.invalidate()

        #expect(snapshots.last?.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "local-last-good"
        ])
    }

    @MainActor
    @Test("relay refresh preserves stale cards through failure and replaces them on recovery")
    func relayRefreshRecoversFromPartialCatalog() async throws {
        let stale = candidate(id: "old", host: "Pangolin", date: 1)
        let complete = [
            stale,
            candidate(id: "new-1", host: "Pangolin", date: 2),
            candidate(id: "new-2", host: "Pangolin", date: 3),
            candidate(id: "new-3", host: "Pangolin", date: 4),
        ]
        let loads = RelayLoadSequence([[stale], nil, complete])
        let delays = RelayDelayGate()
        let completeUpdate = AsyncSignal()
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []

        model.refresh(
            initial: [],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { [] },
            loadRelay: { await loads.next() },
            isAvailable: { _ in true },
            onUpdate: {
                snapshots.append($0)
                if $0.sections.flatMap(\.items).count == 4 {
                    model.invalidate()
                    Task { await completeUpdate.signal() }
                }
            },
            delay: { _ in await delays.delay() }
        )

        await delays.waitForCall(1)
        #expect(snapshots.last?.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "old"
        ])

        await delays.advance()
        await delays.waitForCall(2)
        #expect(await loads.count() == 2)
        #expect(snapshots.last?.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "old"
        ])

        await delays.advance()
        await completeUpdate.wait()

        #expect(snapshots.last?.sections.flatMap(\.items).map(\.candidate.sessionRef.sessionID) == [
            "new-3", "new-2", "new-1", "old"
        ])
    }

    @MainActor
    @Test("invalidating the picker cancels a pending relay refresh")
    func relayRefreshCancellation() async {
        let loads = RelayLoadSequence([[candidate(id: "old", host: "Pangolin", date: 1)]])
        let delayStarted = AsyncSignal()
        let delayCancelled = AsyncSignal()
        let model = SessionPickerModel()

        model.refresh(
            initial: [],
            excluding: [],
            homeDirectory: "/Users/test",
            loadLocal: { [] },
            loadRelay: { await loads.next() },
            isAvailable: { _ in true },
            onUpdate: { _ in },
            delay: { _ in
                await delayStarted.signal()
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                } catch {
                    await delayCancelled.signal()
                }
            }
        )

        await delayStarted.wait()
        model.invalidate()
        await delayCancelled.wait()

        #expect(await loads.count() == 1)
    }

    private func candidate(
        id: String,
        host: String,
        date: TimeInterval,
        location: SessionLocation? = nil,
        action: SessionPickerCandidate.Action = .attach
    ) -> SessionPickerCandidate {
        SessionPickerCandidate(
            sessionRef: SessionRef(location: location ?? .relayMac(host), sessionID: id),
            hostTitle: host,
            title: id,
            cwd: "/Users/test/\(id)",
            isClosed: false,
            createdAt: Date(timeIntervalSince1970: date),
            commandCount: 1,
            runningCommand: nil,
            commandHistory: [],
            action: action
        )
    }
}
