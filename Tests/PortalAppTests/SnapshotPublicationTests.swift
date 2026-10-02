import Combine
import Foundation
import Testing
@testable import PortalApp
@testable import PortalEngine
import PortalCore

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

@Test("toolbar backup status follows project transfer state and pause")
@MainActor
func backupToolbarProgress() {
    let model = AppModel(connectToHelper: false)
    #expect(model.backupToolbarStatus == "Backup not configured")
    model.configuration.backupDestination = BackupDestinationConfiguration(root: "/tmp/backups")
    model.isRunning = true
    model.selectProject("project")
    #expect(model.backupToolbarStatus == "Checking backup…")
    model.backupTransferring["project"] = true
    #expect(model.backupToolbarStatus == "Transferring backup objects…")
    model.backupTransferring["project"] = false
    #expect(model.backupToolbarStatus == "Backup up to date")
    model.isPaused = true
    #expect(model.backupToolbarStatus == "Backup paused")
    model.backupError = "Disconnected"
    #expect(model.backupToolbarStatus == "Backup unavailable")
}
