import Foundation
import Testing
@testable import VaulttyCore

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

    @Test("restore ignores direct SSH sessions")
    func restoreIgnoresDirectSSH() throws {
        var visibleSSH = record(id: "visible-ssh", windowID: "window", createdAt: 2)
        visibleSSH.sessionRef = SessionRef(location: .sshHost("host"), sessionID: visibleSSH.sessionID)
        var closedSSH = record(id: "closed-ssh", windowID: nil, createdAt: 1)
        closedSSH.sessionRef = SessionRef(location: .sshHost("host"), sessionID: closedSSH.sessionID)
        let local = record(id: "local", windowID: "window", createdAt: 3)
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [visibleSSH, local],
            closedTabs: [closedSSH],
            activeSessionID: nil,
            activeSessionIDs: nil
        )))
        let catalog = SessionCatalog(store: store, windowID: "window")

        let restoration = catalog.restore(restoresPersistedWindow: true)

        #expect(restoration.tabs.map(\.sessionID) == ["local"])
        #expect(catalog.closedTabs.isEmpty)
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

    @Test("development namespace sessions are never persisted")
    func developmentNamespaceIsExcludedFromPersistence() throws {
        let portalID = SessionDaemonIdentity(
            namespace: .portalDevelopment,
            rawSessionID: "portal-session"
        ).externalSessionID
        let existingPortal = record(id: portalID, windowID: "other-window", createdAt: 1)
        let store = MemorySessionCatalogStore(data: try JSONEncoder().encode(TestCatalogStorage(
            visibleTabs: [existingPortal],
            closedTabs: [existingPortal],
            activeSessionID: portalID,
            activeSessionIDs: ["other-window": portalID]
        )))
        let catalog = SessionCatalog(store: store, windowID: "this-window")
        _ = catalog.restore(restoresPersistedWindow: false)

        catalog.appendClosed(existingPortal)
        try catalog.persist(visibleTabs: [existingPortal], activeSessionRef: existingPortal.resolvedRef)

        let stored = try JSONDecoder().decode(TestCatalogStorage.self, from: try #require(store.data))
        #expect(stored.visibleTabs.isEmpty)
        #expect(stored.closedTabs.isEmpty)
        #expect(stored.activeSessionIDs?.isEmpty == true)
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
