import Foundation

protocol SessionCatalogStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct FileSessionCatalogStore: SessionCatalogStore {
    let url: URL

    func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

final class SessionCatalog {
    struct Record: Codable {
        var sessionRef: SessionRef?
        var sessionID: String
        var title: String
        var cwd: String
        var windowID: String?
        var createdAt: Date?
        var commandCount: Int?
        var runningCommand: String?
        var commandHistory: [String]?

        var resolvedRef: SessionRef {
            sessionRef ?? .local(sessionID)
        }
    }

    struct Restoration {
        var windowID: String
        var tabs: [Record]
    }

    private struct Storage: Codable {
        var visibleTabs: [Record]
        var closedTabs: [Record]
        var activeSessionID: String?
        var activeSessionIDs: [String: String]?
    }

    private let store: any SessionCatalogStore
    private(set) var windowID: String
    private(set) var closedTabs: [Record] = []
    private var exitedSessionIDs = Set<String>()
    private var exitedSessionRefs = Set<SessionRef>()

    convenience init(url: URL, windowID: String) {
        self.init(store: FileSessionCatalogStore(url: url), windowID: windowID)
    }

    init(store: any SessionCatalogStore, windowID: String) {
        self.store = store
        self.windowID = windowID
    }

    func restore(restoresPersistedWindow: Bool) -> Restoration {
        let storage = load()
        let persistedVisibleTabs = storage.visibleTabs.filter(shouldRestore)
        closedTabs = storage.closedTabs.filter(shouldRestore)

        if restoresPersistedWindow,
           let restoredWindowID = persistedVisibleTabs.compactMap(\.windowID).first,
           !persistedVisibleTabs.contains(where: { $0.windowID == windowID }) {
            windowID = restoredWindowID
        }

        let activeSessionID = storage.activeSessionIDs?[windowID] ?? storage.activeSessionID
        let newestFirst = persistedVisibleTabs
            .filter { $0.windowID == nil || $0.windowID == windowID }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        guard let activeSessionID,
              let activeIndex = newestFirst.firstIndex(where: { $0.sessionID == activeSessionID })
        else {
            return Restoration(windowID: windowID, tabs: newestFirst)
        }
        var ordered = newestFirst
        let active = ordered.remove(at: activeIndex)
        ordered.insert(active, at: 0)
        return Restoration(windowID: windowID, tabs: ordered)
    }

    func persist(visibleTabs: [Record], activeSessionRef: SessionRef?) throws {
        let existing = load()
        let otherWindowTabs = existing.visibleTabs.filter { record in
            guard let storedWindowID = record.windowID else { return false }
            return storedWindowID != windowID && shouldPersist(record)
        }
        var activeSessionIDs = (existing.activeSessionIDs ?? [:]).filter { _, sessionID in
            !exitedSessionIDs.contains(sessionID)
        }
        if let activeSessionRef, !isExited(activeSessionRef) {
            activeSessionIDs[windowID] = activeSessionRef.sessionID
        } else {
            activeSessionIDs.removeValue(forKey: windowID)
        }
        let currentWindowTabs = visibleTabs.filter(shouldPersist).map { record in
            var record = record
            record.windowID = windowID
            return record
        }
        let storage = Storage(
            visibleTabs: otherWindowTabs + currentWindowTabs,
            closedTabs: closedTabs.filter(shouldPersist),
            activeSessionID: activeSessionRef?.sessionID,
            activeSessionIDs: activeSessionIDs
        )
        try store.write(JSONEncoder().encode(storage))
    }

    func visibleRecords() -> [Record] {
        load().visibleTabs.filter(shouldPersist)
    }

    func isVisibleOutsideCurrentWindow(_ sessionRef: SessionRef) -> Bool {
        visibleRecords().contains { record in
            record.resolvedRef == sessionRef && record.windowID != nil && record.windowID != windowID
        }
    }

    func appendClosed(_ record: Record) {
        guard shouldPersist(record), !closedTabs.contains(where: { $0.resolvedRef == record.resolvedRef }) else {
            return
        }
        closedTabs.append(record)
    }

    func popLastClosed() -> Record? {
        closedTabs.popLast()
    }

    func removeClosed(_ sessionRef: SessionRef) {
        closedTabs.removeAll { $0.resolvedRef == sessionRef }
    }

    func removeClosed(_ sessionRefs: Set<SessionRef>) {
        closedTabs.removeAll { sessionRefs.contains($0.resolvedRef) }
    }

    func restoreClosed(_ records: [Record]) {
        var seen = Set(closedTabs.map(\.resolvedRef))
        closedTabs.append(contentsOf: records.filter {
            shouldPersist($0) && seen.insert($0.resolvedRef).inserted
        })
    }

    @discardableResult
    func markExited(_ sessionRef: SessionRef) -> Bool {
        let insertedID = exitedSessionIDs.insert(sessionRef.sessionID).inserted
        let insertedRef = exitedSessionRefs.insert(sessionRef).inserted
        let count = closedTabs.count
        removeClosed(sessionRef)
        return insertedID || insertedRef || closedTabs.count != count
    }

    func shouldPersist(_ record: Record) -> Bool {
        (record.commandCount ?? 0) > 0 && !isExited(record.resolvedRef)
    }

    private func shouldRestore(_ record: Record) -> Bool {
        guard shouldPersist(record) else { return false }
        if case .sshHost = record.resolvedRef.location { return false }
        return true
    }

    func isExited(_ sessionRef: SessionRef) -> Bool {
        exitedSessionRefs.contains(sessionRef) || exitedSessionIDs.contains(sessionRef.sessionID)
    }

    private func load() -> Storage {
        guard let data = try? store.read(),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else {
            return Storage(visibleTabs: [], closedTabs: [], activeSessionID: nil, activeSessionIDs: nil)
        }
        return storage
    }
}
