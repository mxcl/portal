import Combine
import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncEngine
import GitSyncCore

@Test("identical and log-only helper snapshots do not invalidate project views")
@MainActor
func unchangedSnapshotIsSilent() {
    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: AppConfiguration(root: "", machine: "test"),
        support: FileManager.default.temporaryDirectory)
    let model = AppModel(connectToHelper: false)
    var snapshot = engine.snapshot()
    model.apply(snapshot)
    var changes = 0
    let observation = model.objectWillChange.sink { changes += 1 }
    model.apply(snapshot)
    snapshot.logs = ["background replication progress"]
    model.apply(snapshot)
    #expect(changes == 0)
    snapshot.github.status = "Changed"
    model.apply(snapshot)
    #expect(changes == 1)
    #expect(model.github.status == "Changed")
    withExtendedLifetime(observation) {}
}
