import Foundation
import GitSyncCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func values(_ name: String, in arguments: [String]) -> [String] {
    arguments.indices.compactMap { index in
        arguments[index] == name && arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }
}

func required(_ name: String, in arguments: [String]) throws -> String {
    guard let result = value(name, in: arguments) else {
        throw SyncError.invalidConfiguration("Missing \(name)")
    }
    return result
}

func defaultStateURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/git-sync/state.json")
}

let usage = """
Usage:
  git-sync run --root PATH --machine NAME --peer SSH_TARGET --remote-root PATH [--remote-machine NAME] [--remote-executable PATH] [--selective --repository NAME ...] [--sync-checkouts] [--state PATH]
  git-sync run --config PATH [--state PATH]
  git-sync daemon --stdio --root PATH [--machine NAME] [--selective --repository NAME ...] [--receive-only] [--sync-checkouts] [--state PATH]
  git-sync list --root PATH
  git-sync inspect --root PATH [--machine NAME]
  git-sync project-state --root PATH --repository NAME --placement checkedOut|mirrored|notPresent [--branch NAME]
  git-sync check-backup
  git-sync relay-backup
  git-sync relay-backup-control
  git-sync sync-once --source-root PATH --destination-root PATH --machine NAME [--sync-checkouts] [--state PATH]
"""

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else { print(usage); exit(64) }
    arguments.removeFirst()
    let stateURL = URL(fileURLWithPath: NSString(string: value("--state", in: arguments) ?? defaultStateURL().path).expandingTildeInPath)
    let log: (String) -> Void = { message in
        FileHandle.standardError.write(Data("[git-sync] \(message)\n".utf8))
    }

    switch command {
    case "run":
        let configuration: Configuration
        if let path = value("--config", in: arguments) {
            configuration = try Configuration.load(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        } else {
            configuration = Configuration(
                root: try required("--root", in: arguments),
                machine: try required("--machine", in: arguments),
                peer: try required("--peer", in: arguments),
                remoteRoot: try required("--remote-root", in: arguments),
                remoteExecutable: value("--remote-executable", in: arguments) ?? Configuration.defaultRemoteExecutable,
                repositories: arguments.contains("--selective") ? values("--repository", in: arguments) : nil,
                remoteMachine: value("--remote-machine", in: arguments),
                syncCheckouts: arguments.contains("--sync-checkouts")
            )
        }
        try Runner.connect(configuration, stateURL: stateURL, logger: log)
    case "daemon":
        guard arguments.contains("--stdio") else { throw SyncError.invalidConfiguration("daemon requires --stdio") }
        let root = URL(fileURLWithPath: NSString(string: try required("--root", in: arguments)).expandingTildeInPath)
        let repositories = values("--repository", in: arguments)
        try Runner.serve(root: root, machine: value("--machine", in: arguments) ?? Configuration.defaultMachine,
                         stateURL: stateURL,
                         repositories: arguments.contains("--selective") ? Set(repositories) : nil,
                         receiveOnly: arguments.contains("--receive-only"),
                         syncCheckouts: arguments.contains("--sync-checkouts"),
                         logger: log)
    case "list":
        let root = URL(fileURLWithPath: NSString(string: try required("--root", in: arguments)).expandingTildeInPath)
        let data = try JSONEncoder().encode(Repository.discover(in: root).map(\.name))
        print(String(decoding: data, as: UTF8.self))
    case "inspect":
        let root = URL(fileURLWithPath: NSString(string: try required("--root", in: arguments)).expandingTildeInPath)
        let repositories = try Repository.discover(in: root)
        let inspection = PeerInspection(version: SyncProtocol.version,
                                        machine: value("--machine", in: arguments) ?? Configuration.defaultMachine,
                                        repositories: repositories.map(\.name),
                                        projects: repositories.map {
                                            PeerProject(name: $0.name, placement: $0.placement,
                                                        defaultBranch: $0.defaultBranch)
                                        })
        print(String(decoding: try JSONEncoder().encode(inspection), as: UTF8.self))
    case "project-state":
        let root = URL(fileURLWithPath: NSString(string: try required("--root", in: arguments)).expandingTildeInPath)
        let name = try required("--repository", in: arguments)
        guard let placement = ProjectPlacement(rawValue: try required("--placement", in: arguments)),
              placement != .unknown else {
            throw SyncError.invalidConfiguration("Invalid project placement")
        }
        let repository = try Repository.setPlacement(name: name, in: root, to: placement,
                                                      branch: value("--branch", in: arguments))
        let result = PeerProject(name: name,
                                 placement: placement == .notPresent ? .notPresent : repository.placement,
                                 defaultBranch: placement == .notPresent ? nil : repository.defaultBranch)
        print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
    case "check-backup":
        try LocalBackupTransport.connect(mode: LocalBackupTransport.check).close()
    case "relay-backup":
        try LocalBackupTransport.relayStandardIO()
    case "relay-backup-control":
        try LocalBackupTransport.relayStandardIO(to: LocalBackupTransport.controlSocketURL)
    case "sync-once":
        let source = URL(fileURLWithPath: NSString(string: try required("--source-root", in: arguments)).expandingTildeInPath)
        let destination = URL(fileURLWithPath: NSString(string: try required("--destination-root", in: arguments)).expandingTildeInPath)
        try OneShot.sync(sourceRoot: source, destinationRoot: destination,
                         machine: try required("--machine", in: arguments), stateURL: stateURL,
                         syncCheckouts: arguments.contains("--sync-checkouts"))
    case "help", "--help", "-h": print(usage)
    default: throw SyncError.invalidConfiguration("Unknown command: \(command)\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("git-sync: \(error)\n".utf8))
    exit(1)
}
