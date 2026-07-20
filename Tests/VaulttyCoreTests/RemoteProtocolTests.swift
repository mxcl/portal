import Foundation
import Testing
@testable import VaulttyCore

@Suite("Remote protocol")
struct RemoteProtocolTests {
    @Test("messages preserve opaque terminal payloads")
    func messageRoundTrip() throws {
        let message = RemoteMessage(
            kind: .terminalEvent,
            requestID: "request",
            macID: "mac",
            sessionID: "session",
            sequence: 42,
            payload: Data([0, 1, 2, 255])
        )

        let decoded = try JSONDecoder().decode(
            RemoteMessage.self,
            from: JSONEncoder().encode(message)
        )

        #expect(decoded == message)
    }

    @Test("sequence tracker rejects replay and detects gaps")
    func sequenceValidation() {
        var tracker = RemoteSequenceTracker()

        #expect(tracker.accept(7) == .accepted)
        #expect(tracker.accept(7) == .duplicate)
        #expect(tracker.accept(9) == .gap(expected: 8))
        #expect(tracker.accept(8) == .accepted)
        #expect(tracker.lastSequence == 8)
    }
}
