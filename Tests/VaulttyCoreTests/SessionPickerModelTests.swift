import Foundation
import Testing
@testable import VaulttyCore

@Suite("Session picker model")
struct SessionPickerModelTests {
    @MainActor
    @Test("groups the same host discovered through SSH and relay once")
    func groupsHostAcrossTransports() async throws {
        let model = SessionPickerModel()
        var snapshots: [SessionPickerSnapshot] = []

        model.refresh(
            initial: [],
            excluding: [],
            homeDirectory: "/Users/test",
            loadSSH: {
                [candidate(
                    id: "ssh-session",
                    host: "pangolin",
                    date: 1,
                    location: .sshHost("pangolin-ssh")
                )]
            },
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
        #expect(final.sections[0].items.count == 1)
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
            loadSSH: {
                try? await Task.sleep(nanoseconds: 20_000_000)
                return [oldRemote]
            },
            loadRelay: { [] },
            isAvailable: { _ in true },
            onUpdate: { snapshots.append($0) }
        )
        model.refresh(
            initial: [local],
            excluding: [],
            homeDirectory: "/Users/test",
            loadSSH: { [oldRemote, oldRemote] },
            loadRelay: { [candidate(id: "alpha", host: "Alpha", date: 3)] },
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
            sessionRef: SessionRef(location: location ?? .sshHost(host), sessionID: id),
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
