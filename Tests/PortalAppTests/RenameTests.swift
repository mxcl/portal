import Foundation
import Testing
@testable import PortalApp
@testable import PortalCore
@testable import PortalEngine

@Test("rename sheet belongs to the initiating window and survives unrelated snapshots")
@MainActor
func renameSheetLifetime() async throws {
    let record = ProjectRename.Record(old: "before", new: "after")
    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: AppConfiguration(root: "", machine: "test"),
        support: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.snapshot())) as? [String: Any])
    payload["renameProgress"] = "renaming"
    payload["placementInProgress"] = "rename"
    payload["error"] = "Transient watcher warning"
    let snapshot = try JSONDecoder().decode(EngineSnapshot.self, from: JSONSerialization.data(withJSONObject: payload))
    let otherWindow = AppModel(connectToHelper: false)
    otherWindow.apply(snapshot)
    #expect(otherWindow.renameRequest == nil)

    var model: AppModel!
    model = AppModel(connectToHelper: false) { command in
        guard case .renameProject(let received) = command else {
            Issue.record("Unexpected command")
            return EngineReply()
        }
        #expect(received == record)
        #expect(model.renameRequest == record)
        model.apply(engine.snapshot())
        #expect(model.renameRequest == record)
        #expect(model.placementInProgress == "rename")
        model.apply(snapshot)
        model.cancelRename()
        #expect(!model.cancellingRename)
        return EngineReply(snapshot: snapshot)
    }
    await model.renameProject(record)?.value
    #expect(model.renameRequest == nil)
    #expect(model.selectedProjectName == "after")
    #expect(model.error == "Transient watcher warning")
}

@Test("cancel requests the matching operation and keeps progress until acknowledgement")
@MainActor
func renameSheetCancellation() async throws {
    let record = ProjectRename.Record(old: "before", new: "after")
    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        configuration: AppConfiguration(root: "", machine: "test"),
        support: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    var model: AppModel!
    var completion: CheckedContinuation<EngineReply, Never>?
    model = AppModel(connectToHelper: false) { command in
        switch command {
        case .renameProject:
            var snapshot = engine.snapshot()
            snapshot.renameProgress = .checking
            model.apply(snapshot)
            return await withCheckedContinuation { completion = $0 }
        case .cancelProjectRename(let id):
            #expect(id == record.id)
            #expect(model.renameRequest == record)
            #expect(model.cancellingRename)
            completion?.resume(returning: EngineReply(cancelled: true))
            return EngineReply()
        default:
            Issue.record("Unexpected command")
            return EngineReply()
        }
    }
    let task = try #require(model.renameProject(record))
    let deadline = Date().addingTimeInterval(5)
    while completion == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(completion != nil)
    model.cancelRename()
    #expect(model.renameRequest == record)
    await task.value
    #expect(model.renameRequest == nil)
    #expect(model.selectedProjectName != "after")
    #expect(model.error == nil)
}

@Test("rename connection failure dismisses the sheet and reports the failure")
@MainActor
func renameSheetFailure() async throws {
    let model = AppModel(connectToHelper: false) { _ in throw SyncError.disconnected }
    await model.renameProject(.init(old: "before", new: "after"))?.value
    #expect(model.renameRequest == nil)
    #expect(model.placementInProgress == nil)
    #expect(model.error != nil)
}
