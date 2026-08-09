import Foundation
import Testing
@testable import PortalCore

@Suite("Relay client")
struct RelayClientTests {
    @Test("a repeated ping callback completes only once")
    func repeatedPingCallbackCompletesOnce() async {
        let gate = OneShotGate()
        let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<100 {
                group.addTask { gate.claim() }
            }
            var count = 0
            for await didClaim in group where didClaim {
                count += 1
            }
            return count
        }

        #expect(accepted == 1)
    }
}
