import Foundation
import Testing
@testable import VaulttyCore

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
