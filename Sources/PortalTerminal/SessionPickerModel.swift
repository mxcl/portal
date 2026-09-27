#if os(macOS)
import Foundation

struct SessionPickerCandidate: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case attach
        case create
    }

    var sessionRef: SessionRef
    var hostTitle: String
    var title: String
    var cwd: String
    var isClosed: Bool
    var createdAt: Date?
    var commandCount: Int
    var lastCommandAt: Date? = nil
    var runningCommand: String?
    var commandHistory: [String]
    var action: Action
    var attachedClientCount: Int? = nil

    var canExit: Bool {
        action == .attach && (isClosed || attachedClientCount == 0)
    }
}

struct SessionPickerItem: Equatable, Sendable {
    var candidate: SessionPickerCandidate
    var title: String
    var subtitle: String?
    var metadata: String
}

struct SessionPickerSection: Equatable, Sendable {
    var location: SessionLocation
    var title: String
    var newSession: SessionPickerCandidate?
    var items: [SessionPickerItem]
}

struct SessionPickerSnapshot: Equatable, Sendable {
    var sections: [SessionPickerSection]

    func matchingItems(_ query: String) -> [SessionPickerItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return sections.flatMap(\.items).enumerated().compactMap {
            offset, item -> (rank: Int, offset: Int, item: SessionPickerItem)? in
            let fields = [item.title, item.subtitle, item.candidate.cwd].compactMap { $0 }
            let cwdName = URL(fileURLWithPath: item.candidate.cwd).lastPathComponent
            let rank: Int
            if cwdName.caseInsensitiveCompare(query) == .orderedSame {
                rank = 0
            } else if fields.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
                rank = 1
            } else if fields.contains(where: { $0.range(of: query, options: [.caseInsensitive, .anchored]) != nil }) {
                rank = 2
            } else if fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
                rank = 3
            } else {
                return nil
            }
            return (rank, offset, item)
        }.sorted {
            ($0.rank, $0.offset) < ($1.rank, $1.offset)
        }.map(\.item)
    }
}

@MainActor
final class SessionPickerModel {
    @MainActor
    final class Inventory {
        // Keep successful inventories across picker instances, including confirmed empty lists.
        var local: [SessionPickerCandidate]?
        var remote: [SessionPickerCandidate]?
    }

    private let inventory: Inventory

    init(inventory: Inventory? = nil) {
        self.inventory = inventory ?? Inventory()
    }

    typealias RetryingLoader = @Sendable () async -> [SessionPickerCandidate]?
    typealias Delay = @Sendable (UInt64) async -> Void

    private enum LoadResult: Sendable {
        case local([SessionPickerCandidate])
        case remote([SessionPickerCandidate]?)
    }

    private var generation = 0
    private var loadTask: Task<Void, Never>?

    func refresh(
        initial: [SessionPickerCandidate],
        excluding: Set<SessionRef>,
        homeDirectory: String,
        loadLocal: @escaping RetryingLoader,
        loadRemote: @escaping RetryingLoader,
        isAvailable: @escaping @MainActor (SessionRef) -> Bool,
        onUpdate: @escaping @MainActor (SessionPickerSnapshot) -> Void,
        remoteSuccessDelay: UInt64 = 2_000_000_000,
        remoteFailureDelays: [UInt64] = [500_000_000, 2_000_000_000, 5_000_000_000],
        delay: @escaping Delay = { try? await Task.sleep(nanoseconds: $0) }
    ) {
        invalidate()
        let generation = generation
        var unconfirmedInitialCandidates = initial.filter {
            switch $0.sessionRef.location {
            case .local: inventory.local == nil
            // Saved remote history is metadata, not evidence that a session still exists.
            case .sshHost: inventory.remote == nil
            }
        }
        let initialCommandRecency = initial.reduce(into: [SessionRef: Date]()) { result, candidate in
            if let lastCommandAt = candidate.lastCommandAt {
                result[candidate.sessionRef] = lastCommandAt
            }
        }
        let initialCommandHistory = Dictionary(uniqueKeysWithValues: initial.map {
            ($0.sessionRef, $0.commandHistory)
        })
        func preservingInitialCommandState(
            _ candidates: [SessionPickerCandidate]
        ) -> [SessionPickerCandidate] {
            candidates.map { candidate in
                var candidate = candidate
                candidate.lastCommandAt = candidate.lastCommandAt
                    ?? initialCommandRecency[candidate.sessionRef]
                if case .sshHost = candidate.sessionRef.location,
                   candidate.commandHistory.isEmpty {
                    candidate.commandHistory = initialCommandHistory[candidate.sessionRef] ?? []
                }
                return candidate
            }
        }
        let failureDelays = remoteFailureDelays.isEmpty ? [5_000_000_000] : remoteFailureDelays
        let cachedLocal = preservingInitialCommandState(inventory.local ?? [])
        let cachedRemote = preservingInitialCommandState(inventory.remote ?? [])
        onUpdate(snapshot(
            from: combinedCandidates(
                initial: unconfirmedInitialCandidates,
                local: cachedLocal,
                remote: cachedRemote,
                excluding: excluding,
                isAvailable: isAvailable
            ),
            homeDirectory: homeDirectory
        ))

        loadTask = Task { [weak self] in
            await withTaskGroup(of: LoadResult.self) { group in
                group.addTask {
                    let retryDelays: [UInt64] = [100_000_000, 500_000_000, 2_000_000_000]
                    var attempt = 0
                    while !Task.isCancelled {
                        if let local = await loadLocal() { return .local(local) }
                        try? await Task.sleep(nanoseconds: retryDelays[min(attempt, retryDelays.count - 1)])
                        attempt += 1
                    }
                    return .local([])
                }
                group.addTask { .remote(await loadRemote()) }
                var localCandidates = cachedLocal
                var remoteCandidates = cachedRemote
                var remoteFailureAttempt = 0
                for await result in group {
                    guard let self, generation == self.generation, !Task.isCancelled else { return }
                    switch result {
                    case .local(let additions):
                        unconfirmedInitialCandidates.removeAll {
                            if case .local = $0.sessionRef.location { return true }
                            return false
                        }
                        localCandidates = preservingInitialCommandState(additions)
                        self.inventory.local = localCandidates
                        onUpdate(self.snapshot(
                            from: self.combinedCandidates(
                                initial: unconfirmedInitialCandidates,
                                local: localCandidates,
                                remote: remoteCandidates,
                                excluding: excluding,
                                isAvailable: isAvailable
                            ),
                            homeDirectory: homeDirectory
                        ))
                    case .remote(let result):
                        let retryDelay: UInt64
                        if let result {
                            unconfirmedInitialCandidates.removeAll { if case .sshHost = $0.sessionRef.location { return true }; return false }
                            remoteCandidates = preservingInitialCommandState(result)
                            self.inventory.remote = remoteCandidates
                            remoteFailureAttempt = 0
                            retryDelay = remoteSuccessDelay
                            onUpdate(self.snapshot(
                                from: self.combinedCandidates(
                                    initial: unconfirmedInitialCandidates,
                                    local: localCandidates,
                                    remote: remoteCandidates,
                                    excluding: excluding,
                                    isAvailable: isAvailable
                                ),
                                homeDirectory: homeDirectory
                            ))
                        } else {
                            retryDelay = failureDelays[
                                min(remoteFailureAttempt, failureDelays.count - 1)
                            ]
                            remoteFailureAttempt += 1
                        }
                        guard generation == self.generation, !Task.isCancelled else { return }
                        group.addTask {
                            await delay(retryDelay)
                            guard !Task.isCancelled else { return .remote(nil) }
                            return .remote(await loadRemote())
                        }
                    }
                }
            }
        }
    }

    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func combinedCandidates(
        initial: [SessionPickerCandidate],
        local: [SessionPickerCandidate],
        remote: [SessionPickerCandidate],
        excluding: Set<SessionRef>,
        isAvailable: @MainActor (SessionRef) -> Bool
    ) -> [SessionPickerCandidate] {
        var candidates: [SessionPickerCandidate] = []
        merge(initial, into: &candidates, excluding: excluding, isAvailable: isAvailable)
        merge(local, into: &candidates, excluding: excluding, isAvailable: isAvailable)
        for candidate in remote {
            candidates.removeAll { $0.sessionRef == candidate.sessionRef }
            merge([candidate], into: &candidates, excluding: excluding, isAvailable: isAvailable)
        }
        return candidates
    }

    private func merge(
        _ additions: [SessionPickerCandidate],
        into candidates: inout [SessionPickerCandidate],
        excluding: Set<SessionRef>,
        isAvailable: @MainActor (SessionRef) -> Bool
    ) {
        var seen = Set(candidates.map(\.sessionRef))
        for candidate in additions where
            !excluding.contains(candidate.sessionRef) &&
            isAvailable(candidate.sessionRef) &&
            seen.insert(candidate.sessionRef).inserted
        {
            candidates.append(candidate)
        }
    }

    private func snapshot(
        from candidates: [SessionPickerCandidate],
        homeDirectory: String
    ) -> SessionPickerSnapshot {
        let ordered = candidates.sorted {
            let lhsDate = $0.lastCommandAt ?? $0.createdAt ?? .distantPast
            let rhsDate = $1.lastCommandAt ?? $1.createdAt ?? .distantPast
            return lhsDate == rhsDate
                ? $0.sessionRef.sessionID < $1.sessionRef.sessionID
                : lhsDate > rhsDate
        }
        let sections = Dictionary(grouping: ordered) { $0.hostTitle.lowercased() }
            .map { _, candidates in
                SessionPickerSection(
                    location: candidates[0].sessionRef.location,
                    title: candidates[0].hostTitle,
                    newSession: candidates.first { $0.action != .attach },
                    items: candidates
                        .filter { $0.action == .attach }
                        .map { item(for: $0, homeDirectory: homeDirectory) }
                )
            }
            .sorted {
                switch ($0.location, $1.location) {
                case (.local, .local):
                    false
                case (.local, _):
                    false
                case (_, .local):
                    true
                default:
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }
        return SessionPickerSnapshot(sections: sections)
    }

    private func item(
        for candidate: SessionPickerCandidate,
        homeDirectory: String
    ) -> SessionPickerItem {
        let runningCommand = candidate.runningCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRunningCommand = runningCommand?.isEmpty == false
        let title = runningCommand.flatMap { command in
            hasRunningCommand
                ? command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                : nil
        } ?? display(cwd: candidate.cwd, homeDirectory: homeDirectory)
        let subtitle = hasRunningCommand
            ? display(cwd: candidate.cwd, homeDirectory: homeDirectory)
            : nil
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        let lastCommand = candidate.lastCommandAt.map {
            "Last command \(formatter.localizedString(for: $0, relativeTo: Date.now))"
        } ?? "Last command unknown"
        let commandCount = candidate.commandCount == 1
            ? "1 command"
            : "\(candidate.commandCount) commands"
        let sessionAge = candidate.createdAt.map {
            formatter.localizedString(for: $0, relativeTo: Date.now)
                .replacingOccurrences(of: " ago", with: " old")
        } ?? "Session age unknown"
        let metadata = "\(lastCommand) · \(commandCount) · \(sessionAge)"
        return SessionPickerItem(
            candidate: candidate,
            title: title,
            subtitle: subtitle,
            metadata: metadata
        )
    }

    private func display(cwd: String, homeDirectory: String) -> String {
        if cwd == homeDirectory {
            return "~"
        }
        if cwd.hasPrefix(homeDirectory + "/") {
            return "~" + String(cwd.dropFirst(homeDirectory.count))
        }
        return cwd
    }
}

#endif
