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
            loadLocal: { [] },
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
            loadLocal: { [] },
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
