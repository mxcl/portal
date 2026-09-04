import Testing
@testable import GitSyncApp

@Test("event log counts only adjacent repeated events")
func eventLogCountsAdjacentRepeats() {
    #expect(countedEvents(["Fetch", "Fetch", "Idle", "Fetch"]) == [
        CountedEvent(message: "Fetch", count: 2),
        CountedEvent(message: "Idle"),
        CountedEvent(message: "Fetch"),
    ])
}
