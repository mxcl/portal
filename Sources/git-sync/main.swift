import Foundation
import GitSyncCore

func value(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func required(_ name: String, in arguments: [String]) throws -> String {
    guard let result = value(name, in: arguments) else {
        throw SyncError.invalidConfiguration("Missing \(name)")
    }
    return result
}

func defaultMachine() -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let name = ProcessInfo.processInfo.hostName.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    return String(name).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
}

func defaultStateURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/git-sync/state.json")
}

let usage = """
Usage:
  git-sync run --root PATH --machine NAME --peer SSH_TARGET --remote-root PATH [--remote-executable PATH] [--state PATH]
  git-sync run --config PATH [--state PATH]
  git-sync daemon --stdio --root PATH [--machine NAME] [--state PATH]
  git-sync sync-once --source-root PATH --destination-root PATH --machine NAME [--state PATH]
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
                remoteExecutable: value("--remote-executable", in: arguments) ?? "git-sync"
            )
        }
        try Runner.connect(configuration, stateURL: stateURL, logger: log)
    case "daemon":
        guard arguments.contains("--stdio") else { throw SyncError.invalidConfiguration("daemon requires --stdio") }
        let root = URL(fileURLWithPath: NSString(string: try required("--root", in: arguments)).expandingTildeInPath)
        try Runner.serve(root: root, machine: value("--machine", in: arguments) ?? defaultMachine(), stateURL: stateURL, logger: log)
    case "sync-once":
        let source = URL(fileURLWithPath: NSString(string: try required("--source-root", in: arguments)).expandingTildeInPath)
        let destination = URL(fileURLWithPath: NSString(string: try required("--destination-root", in: arguments)).expandingTildeInPath)
        try OneShot.sync(sourceRoot: source, destinationRoot: destination,
                         machine: try required("--machine", in: arguments), stateURL: stateURL)
    case "help", "--help", "-h": print(usage)
    default: throw SyncError.invalidConfiguration("Unknown command: \(command)\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("git-sync: \(error)\n".utf8))
    exit(1)
}
