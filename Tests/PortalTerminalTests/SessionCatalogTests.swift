#if os(macOS)
import Foundation
import Testing
@testable import PortalTerminal

private final class MemorySessionCatalogStore: SessionCatalogStore {
    var data: Data?

    init(data: Data? = nil) {
        self.data = data
    }

    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private struct TestCatalogStorage: Codable {
    var visibleTabs: [SessionCatalog.Record]
    var closedTabs: [SessionCatalog.Record]
    var activeSessionID: String?
    var activeSessionIDs: [String: String]?
}

@Suite("Session catalog")
struct SessionCatalogTests {
    @Test("SSH sessions restore in their original project after app closure")
    func restoreSSHSession() throws {
        let store = MemorySessionCatalogStore()
        let catalog = SessionCatalog(store: store, windowID: "project")
        var remote = record(id: "remote", windowID: "project", createdAt: 1)
        remote.sessionRef = SessionRef(location: .sshHost("host"), sessionID: "remote")
        try catalog.persist(visibleTabs: [remote], activeSessionRef: remote.resolvedRef)
        let reopened = SessionCatalog(store: store, windowID: "project")
        #expect(reopened.restore(restoresPersistedWindow: false).tabs.map(\.resolvedRef) == [remote.resolvedRef])
        let other = SessionCatalog(store: store, windowID: "other-project")
        #expect(other.restore(restoresPersistedWindow: false).tabs.isEmpty)
    }

    @Test("folder opens select the most recent session on the local host")
    func mostRecentFolderSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alias = directory.appendingPathExtension("alias")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        var older = record(id: "older", windowID: "one", createdAt: 10)
        older.cwd = directory.path
        older.lastCommandAt = Date(timeIntervalSince1970: 30)
        var newer = record(id: "newer", windowID: "two", createdAt: 20)
        newer.cwd = alias.path
        var remote = record(id: "remote", windowID: "three", createdAt: 100)
        remote.cwd = directory.path
        remote.sessionRef = SessionRef(location: .sshHost("remote"), sessionID: "remote")
        let records = [newer, remote, older]

        #expect(SessionCatalog.mostRecentLocalSession(in: records, at: alias)?.sessionID == "older")
        older.lastCommandAt = nil
        #expect(SessionCatalog.mostRecentLocalSession(in: [older, newer], at: directory)?.sessionID == "newer")
        #expect(SessionCatalog.mostRecentLocalSession(in: records, at: directory.appendingPathComponent("child")) == nil)
        #expect(SessionCatalog.mostRecentLocalSession(in: [remote], at: directory) == nil)
        #expect(SessionCatalog.mostRecentLocalSession(in: [], at: directory) == nil)
    }

    @Test("restore preserves tab order and selected tab")
    func restoreLegacyState() throws {
        let older = record(id: "older", windowID: "window", createdAt: 10)
        var active = record(id: "active", windowID: "window", createdAt: 20)
        active.sessionRef = nil
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [older, active],
            closedTabs: [record(id: "closed", windowID: nil, createdAt: 5)],
            activeSessionID: nil,
            activeSessionIDs: ["window": "active"]
        )))
        let catalog = SessionCatalog(store: store, windowID: "window")

        let restoration = catalog.restore(restoresPersistedWindow: true)

        #expect(restoration.tabs.map(\.sessionID) == ["older", "active"])
        #expect(restoration.tabs[1].resolvedRef == .local("active"))
        #expect(restoration.activeSessionID == "active")
        #expect(catalog.closedTabs.map(\.sessionID) == ["closed"])
    }

    @Test("restore adopts a persisted window when the new window has no records")
    func restoreAdoptsPersistedWindow() throws {
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [record(id: "remote-window", windowID: "persisted", createdAt: 10)],
            closedTabs: [],
            activeSessionID: nil,
            activeSessionIDs: nil
        )))
        let catalog = SessionCatalog(store: store, windowID: "new")

        let restoration = catalog.restore(restoresPersistedWindow: true)

        #expect(restoration.windowID == "persisted")
        #expect(restoration.tabs.map(\.sessionID) == ["remote-window"])
    }

    @Test("restore adopts the most recently persisted window")
    func restoreAdoptsMostRecentPersistedWindow() throws {
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [
                record(id: "stale-one", windowID: "stale", createdAt: 1),
                record(id: "stale-two", windowID: "stale", createdAt: 2),
                record(id: "current", windowID: "recent", createdAt: 3),
            ],
            closedTabs: [],
            activeSessionID: nil,
            activeSessionIDs: nil
        )))
        let catalog = SessionCatalog(store: store, windowID: "new")

        let restoration = catalog.restore(restoresPersistedWindow: true)

        #expect(restoration.tabs.map(\.sessionID) == ["current"])
    }


    @Test("persist replaces only the current window and preserves other windows")
    func persistMergesWindows() throws {
        let other = record(id: "other", windowID: "other-window", createdAt: 1)
        let stale = record(id: "stale", windowID: "this-window", createdAt: 2)
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [other, stale],
            closedTabs: [],
            activeSessionID: nil,
            activeSessionIDs: ["other-window": "other"]
        )))
        let catalog = SessionCatalog(store: store, windowID: "this-window")
        _ = catalog.restore(restoresPersistedWindow: false)
        let current = record(id: "current", windowID: nil, createdAt: 3)

        try catalog.persist(visibleTabs: [current], activeSessionRef: current.resolvedRef)

        let stored = try JSONDecoder().decode(TestCatalogStorage.self, from: try #require(store.data))
        #expect(Set(stored.visibleTabs.map(\.sessionID)) == ["other", "current"])
        #expect(stored.visibleTabs.first(where: { $0.sessionID == "current" })?.windowID == "this-window")
        #expect(stored.activeSessionIDs == ["other-window": "other", "this-window": "current"])
    }

    @Test("closing a window discards only its restoration snapshot")
    func discardWindowRestoration() throws {
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [
                record(id: "other", windowID: "other-window", createdAt: 1),
                record(id: "closed", windowID: "closed-window", createdAt: 2),
            ],
            closedTabs: [],
            activeSessionID: "closed",
            activeSessionIDs: ["other-window": "other", "closed-window": "closed"]
        )))
        let closingCatalog = SessionCatalog(store: store, windowID: "closed-window")
        _ = closingCatalog.restore(restoresPersistedWindow: false)

        try closingCatalog.discardWindowRestoration()

        let reopenedCatalog = SessionCatalog(store: store, windowID: "new-window")
        let restoration = reopenedCatalog.restore(restoresPersistedWindow: true)
        #expect(restoration.windowID == "other-window")
        #expect(restoration.tabs.map(\.sessionID) == ["other"])
        #expect(restoration.activeSessionID == "other")
    }

    @Test("closing the last window discards every restoration snapshot")
    func discardAllWindowRestoration() throws {
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [
                record(id: "stale", windowID: "stale-window", createdAt: 1),
                record(id: "current", windowID: "current-window", createdAt: 2),
            ],
            closedTabs: [],
            activeSessionID: "current",
            activeSessionIDs: ["stale-window": "stale", "current-window": "current"]
        )))
        let closingCatalog = SessionCatalog(store: store, windowID: "current-window")
        _ = closingCatalog.restore(restoresPersistedWindow: false)

        try closingCatalog.discardAllWindowRestoration()

        let reopenedCatalog = SessionCatalog(store: store, windowID: "new-window")
        let restoration = reopenedCatalog.restore(restoresPersistedWindow: true)
        #expect(restoration.tabs.isEmpty)
        #expect(restoration.activeSessionID == nil)
    }



    @Test("exit removes closed history and prevents later persistence")
    func exitFiltersSession() throws {
        let store = MemorySessionCatalogStore()
        let catalog = SessionCatalog(store: store, windowID: "window")
        let exited = record(id: "exited", windowID: nil, createdAt: 1)
        catalog.appendClosed(exited)

        #expect(catalog.markExited(exited.resolvedRef))
        #expect(catalog.closedTabs.isEmpty)
        try catalog.persist(visibleTabs: [exited], activeSessionRef: exited.resolvedRef)

        let stored = try JSONDecoder().decode(TestCatalogStorage.self, from: try #require(store.data))
        #expect(stored.visibleTabs.isEmpty)
        #expect(stored.activeSessionIDs?.isEmpty == true)
    }

    @Test("closed records deduplicate and restore only live sessions")
    func closedRecordPolicy() {
        let catalog = SessionCatalog(store: MemorySessionCatalogStore(), windowID: "window")
        let live = record(id: "live", windowID: nil, createdAt: 1)
        var empty = record(id: "empty", windowID: nil, createdAt: 2)
        empty.commandCount = 0

        catalog.appendClosed(live)
        catalog.appendClosed(live)
        catalog.restoreClosed([empty, live])

        #expect(catalog.closedTabs.map(\.sessionID) == ["live"])
    }

    private func record(
        id: String,
        windowID: String?,
        createdAt: TimeInterval
    ) -> SessionCatalog.Record {
        SessionCatalog.Record(
            sessionRef: .local(id),
            sessionID: id,
            title: id,
            cwd: "/tmp/\(id)",
            windowID: windowID,
            createdAt: Date(timeIntervalSince1970: createdAt),
            commandCount: 1,
            runningCommand: nil,
            commandHistory: [id]
        )
    }
}

#endif
