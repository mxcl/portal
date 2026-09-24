import Foundation
import Testing
@testable import GitSyncApp
@testable import GitSyncCore
@testable import GitSyncEngine

@Test("checkout of an absent local project waits for refs with uninterrupted progress")
@MainActor
func checkoutAbsentProject() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let project = source.appendingPathComponent("project")
    _ = try Git.run(["init", "-q", "-b", "feature/start", project.path])
    _ = try Git.run(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-q", "--allow-empty", "-m", "Initial"])
    let configuration = AppConfiguration(root: destination.path, machine: "test")
    let engine = EngineModel(executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                             configuration: configuration, support: root.appendingPathComponent("support"))
    var model: AppModel!
    var receivedMirror = false
    model = AppModel(connectToHelper: false) { command in
        #expect(model.placementInProgress == "local")
        #expect(model.checkoutRequest == nil)
        switch command {
        case .setPlacement(let placement, let name, let hostID, let branch):
            #expect(hostID == nil)
            if !receivedMirror { #expect(placement == .mirrored) }
            _ = try Repository.setPlacement(name: name, in: destination, to: placement, branch: branch)
            receivedMirror = true
        case .snapshot:
            // An unrelated helper snapshot must not dismiss progress while objects are still arriving.
            model.apply(engine.snapshot())
            #expect(model.placementInProgress == "local")
            try OneShot.sync(sourceRoot: source, destinationRoot: destination, machine: "peer",
                             stateURL: root.appendingPathComponent("state.json"))
        default: Issue.record("Unexpected command")
        }
        return EngineReply(snapshot: engine.snapshot())
    }
    model.configuration = configuration
    model.checkOut("project", hostID: nil)
    #expect(model.placementInProgress == "local")
    let deadline = Date().addingTimeInterval(5)
    while model.placementInProgress != nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(receivedMirror)
    #expect(model.error == nil)
    #expect(model.placementInProgress == nil)
    #expect(model.checkoutRequest?.branches == ["feature/start"])
    #expect(Repository(name: "project", url: destination.appendingPathComponent("project")).placement == .mirrored)
    model.checkoutRequest = nil
    let checkout = try #require(model.setPlacement(.checkedOut, project: "project", hostID: nil, branch: "feature/start"))
    #expect(model.placementInProgress == "local")
    await checkout.value
    #expect(model.error == nil)
    #expect(model.placementInProgress == nil)
    #expect(Repository(name: "project", url: destination.appendingPathComponent("project")).placement == .checkedOut)
}

@Test("placement failure clears progress and exposes the error")
@MainActor
func placementConnectionFailure() async throws {
    let model = AppModel(connectToHelper: false) { _ in
        throw SyncError.invalidConfiguration("Helper disconnected")
    }
    let task = try #require(model.setPlacement(.mirrored, project: "project", hostID: nil))
    #expect(model.placementInProgress == "local")
    await task.value
    #expect(model.placementInProgress == nil)
    #expect(model.checkoutRequest == nil)
    #expect(model.error?.contains("Helper disconnected") == true)
}
