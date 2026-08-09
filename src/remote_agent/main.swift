import Darwin
import Dispatch
import Foundation

@main
struct PortalRemoteAgent {
    @MainActor private static var controller: MacRemoteAccessController?
    private static var singletonLock: RemoteAgentLock?

    @MainActor
    static func main() {
        let lockPath = "/tmp/portal-remote-agent-\(getuid()).lock"
        guard let lock = RemoteAgentLock.acquire(path: lockPath, waitingUpTo: 5) else { return }
        singletonLock = lock
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

}
