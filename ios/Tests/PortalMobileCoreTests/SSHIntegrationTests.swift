import Foundation
import Testing
@testable import PortalMobileCore

// Run only against the disposable sshd started by scripts/test-mobile-ssh.sh.
@Test(.enabled(if: ProcessInfo.processInfo.environment["PORTAL_TEST_SSH_ADDRESS"] != nil))
func directSSHSessionLifecycle() async throws {
    let env = ProcessInfo.processInfo.environment
    let directory = try #require(env["PORTAL_TEST_SSH_DIRECTORY"])
    let token = Data((0..<32).map(UInt8.init))
    try (SSHIdentity.publicKey(token: token) + "\n").write(
        toFile: directory + "/authorized_keys", atomically: true, encoding: .utf8)
    var host = SSHHost()
    host.name = "Integration"
    host.address = try #require(env["PORTAL_TEST_SSH_ADDRESS"])
    host.port = Int(env["PORTAL_TEST_SSH_PORT"] ?? "22992") ?? 22992
    host.username = NSUserName()
    host.homeDirectory = NSHomeDirectory()
    host.hostPublicKey = try String(contentsOfFile: directory + "/host-key.pub", encoding: .utf8)
    let connection = SSHSessionConnection(host: host, token: token)
    let session = try await connection.createSession(peerID: "integration")
    do {
        let listing = try await SSHSessionConnection(host: host, token: token).listSessions()
        #expect(listing.contains { $0.sessionID == session.sessionID })
        let attached = SSHSessionConnection(host: host, token: token)
        let output = CollectedOutput()
        try await attached.run(.joinV2(version: 2, role: .phone, clientID: "integration", sessionID: session.sessionID)) { event in
            switch event {
            case .ready:
                try await attached.send(.input(Data(PortalCommandEnvelope.shellScript(for: "printf portal-ssh-ok").utf8)))
            case .sequencedOutput(_, let text), .output(let text):
                if await output.consume(text) { return false }
            default: break
            }
            return true
        }
        #expect(await output.text.contains("portal-ssh-ok"))
        #expect(await output.text.contains("\u{1b}]133;D;0"))
        let cleanup = SSHSessionConnection(host: host, token: token)
        try await cleanup.run(.kill(sessionID: session.sessionID)) { _ in false }
        let remaining = try await SSHSessionConnection(host: host, token: token).listSessions()
        #expect(!remaining.contains { $0.sessionID == session.sessionID })
        var wrongHost = host
        wrongHost.hostPublicKey = try SSHIdentity.publicKey(token: Data(repeating: 99, count: 32))
        await #expect(throws: (any Error).self) {
            try await SSHSessionConnection(host: wrongHost, token: token).listSessions()
        }
        await #expect(throws: (any Error).self) {
            try await SSHSessionConnection(host: host, token: Data(repeating: 99, count: 32)).listSessions()
        }
    } catch {
        try? await SSHSessionConnection(host: host, token: token).run(.kill(sessionID: session.sessionID)) { _ in false }
        throw error
    }
}

private actor CollectedOutput {
    var text = ""
    func consume(_ value: String) -> Bool {
        text += value
        return text.contains("\u{1b}]133;D;0")
    }
}
