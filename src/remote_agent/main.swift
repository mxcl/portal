import Darwin
import Dispatch
import Foundation

@main
struct VaulttyRemoteAgent {
    @MainActor private static var controller: MacRemoteAccessController?

    @MainActor
    static func main() {
        guard acquireSingletonLock() else { return }
        let arguments = ProcessInfo.processInfo.arguments
        guard let macID = value(after: "--mac-id", in: arguments),
              let endpointValue = value(after: "--endpoint", in: arguments),
              let endpoint = URL(string: endpointValue) else { return }
        let rootKey = FileHandle.standardInput.readDataToEndOfFile()
        guard rootKey.count == RelayCrypto.rootKeyByteCount else { return }
        controller = MacRemoteAccessController(agentMacID: macID, endpoint: endpoint, rootKey: rootKey)
        controller?.startAgentConnection()
        dispatchMain()
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func acquireSingletonLock() -> Bool {
        let path = "/tmp/portal-remote-agent-\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        return true
    }
}
