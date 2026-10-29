import Foundation
import Testing
@testable import PortalCore

@Test("connection catch-up restores an absent accepted peer ref")
func missingAcceptedPeerRef() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    _ = try Git.run(["init", "-q", "-b", "main", source.path])
    _ = try Git.run(["-C", source.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                     "commit", "-qm", "initial", "--allow-empty"])
    let repository = Repository(name: "project", url: source)
    let oid = try Git.text(["-C", source.path, "rev-parse", "HEAD"])
    let epoch = UUID().uuidString
    let stateURL = root.appendingPathComponent("state.json")
    do {
        let state = try StateStore(url: stateURL)
        try state.accept(generation: 1, peer: "A", epoch: epoch, repository: "project", ref: "refs/heads/main")
    }
    let incoming = Pipe(), outgoing = Pipe()
    let session = try SyncSession(root: destination, machine: "B", input: incoming.fileHandleForReading,
        output: outgoing.fileHandleForWriting, stateURL: stateURL, receiveOnly: true, syncCheckouts: true)
    let finished = DispatchGroup()
    finished.enter()
    Thread.detachNewThread { defer { finished.leave() }; try? session.run() }
    defer {
        try? incoming.fileHandleForWriting.close()
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }
    let connection = FramedConnection(input: outgoing.fileHandleForReading, output: incoming.fileHandleForWriting)
    _ = try connection.receiveMessage() // HELLO
    _ = try connection.receiveMessage() // CATALOG
    try connection.send(.hello("A", epoch: epoch))
    try connection.send(update: RefUpdate(repository: "project", sourceRef: "refs/heads/main", generation: 1,
                                         oid: oid, cleanCheckout: true), pack: repository.pack(oid: oid, excluding: []))
    let received = destination.appendingPathComponent("project.git")
    // ACK is sent only after the ref is restored. A wall-clock polling deadline
    // can expire while the receiver waits for a worker during parallel tests.
    let acknowledgement = try connection.receiveMessage()
    #expect(acknowledgement.type == "ack")
    let actual = try Git.text(["-C", received.path, "rev-parse", "--verify", "refs/remotes/a/main"])
    #expect(actual == oid)
    #expect(try Repository(name: "project", url: received).sourceRefs().isEmpty)
}
