import Foundation

struct SessionPickerCandidate: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case attach
        case createSSH(SSHHostRecord)
        case createRelay
    }

    var sessionRef: SessionRef
    var hostTitle: String
    var title: String
    var cwd: String
    var isClosed: Bool
    var createdAt: Date?
    var commandCount: Int
    var runningCommand: String?
    var commandHistory: [String]
    var action: Action
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
}

@MainActor
final class SessionPickerModel {
    typealias Loader = @Sendable () async -> [SessionPickerCandidate]

    private var generation = 0
    private var loadTask: Task<Void, Never>?

    func refresh(
        initial: [SessionPickerCandidate],
        excluding: Set<SessionRef>,
        homeDirectory: String,
        loadSSH: @escaping Loader,
        loadRelay: @escaping Loader,
        isAvailable: @escaping @MainActor (SessionRef) -> Bool,
        onUpdate: @escaping @MainActor (SessionPickerSnapshot) -> Void
    ) {
        invalidate()
        let generation = generation
        var candidates: [SessionPickerCandidate] = []
        merge(initial, into: &candidates, excluding: excluding, isAvailable: isAvailable)
        onUpdate(snapshot(from: candidates, homeDirectory: homeDirectory))

        loadTask = Task { [weak self] in
            let ssh = await loadSSH()
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            self.merge(ssh, into: &candidates, excluding: excluding, isAvailable: isAvailable)
            onUpdate(self.snapshot(from: candidates, homeDirectory: homeDirectory))

            let relay = await loadRelay()
            guard generation == self.generation, !Task.isCancelled else { return }
            self.merge(relay, into: &candidates, excluding: excluding, isAvailable: isAvailable)
            onUpdate(self.snapshot(from: candidates, homeDirectory: homeDirectory))
        }
    }

    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
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
            let lhsDate = $0.createdAt ?? .distantPast
            let rhsDate = $1.createdAt ?? .distantPast
            return lhsDate == rhsDate
                ? $0.sessionRef.sessionID < $1.sessionRef.sessionID
                : lhsDate > rhsDate
        }
        let sections = Dictionary(grouping: ordered, by: \.sessionRef.location)
            .map { location, candidates in
                SessionPickerSection(
                    location: location,
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
        let created = candidate.createdAt.map {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: $0, relativeTo: Date())
        } ?? "earlier"
        let metadata = candidate.commandCount == 0
            ? created
            : "\(created) · \(candidate.commandCount == 1 ? "1 command" : "\(candidate.commandCount) commands")"
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
