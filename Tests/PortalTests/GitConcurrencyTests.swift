import Foundation
import Testing
@testable import PortalCore

@Test("parallel Git calls drain output without starving the executor")
func parallelGitOutput() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
            group.addTask {
                let output = try Git.run(["--version"])
                #expect(String(decoding: output, as: UTF8.self).hasPrefix("git version "))
            }
        }
        try await group.waitForAll()
    }
}
