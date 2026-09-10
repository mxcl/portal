import Foundation
import Testing
@testable import GitSyncApp

@Test func compactCommitAgeUsesAtMostTwoUnitsWithoutSeconds() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let start = try #require(calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    let cases: [(DateComponents, String)] = [
        (DateComponents(second: 59), "0m"),
        (DateComponents(minute: 1), "1m"),
        (DateComponents(hour: 1, minute: 3, second: 59), "1h 3m"),
        (DateComponents(day: 2, hour: 4, minute: 5), "2d 4h"),
        (DateComponents(month: 3, day: 2, hour: 1), "3mn 2d"),
        (DateComponents(year: 1, month: 2, day: 3), "1y 2mn"),
        (DateComponents(year: 1, day: 3), "1y 3d"),
    ]
    #expect(compactCommitAge(from: start, to: start, calendar: calendar) == "0m")
    for (offset, expected) in cases {
        let end = try #require(calendar.date(byAdding: offset, to: start))
        #expect(compactCommitAge(from: start, to: end, calendar: calendar) == expected)
        #expect(compactCommitAge(from: end, to: start, calendar: calendar) == expected)
    }
}
