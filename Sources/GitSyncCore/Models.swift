import Foundation

public struct Configuration: Codable, Equatable, Sendable {
    public static let defaultRemoteExecutable = "/Applications/Git Sync.app/Contents/Resources/git-sync"

    public var root: String
    public var machine: String
    public var peer: String
    public var remoteRoot: String
    public var remoteExecutable: String

    public init(root: String, machine: String, peer: String, remoteRoot: String,
                remoteExecutable: String = Configuration.defaultRemoteExecutable) {
        self.root = root
        self.machine = machine
        self.peer = peer
        self.remoteRoot = remoteRoot
        self.remoteExecutable = remoteExecutable
    }

    public func validate() throws {
        guard FileManager.default.fileExists(atPath: expandedRoot.path) else {
            throw SyncError.invalidConfiguration("Source folder does not exist: \(root)")
        }
        try Validator.machine(machine)
        guard !peer.isEmpty, !peer.hasPrefix("-") else {
            throw SyncError.invalidConfiguration("Invalid SSH peer")
        }
        guard !remoteRoot.isEmpty, !remoteExecutable.isEmpty else {
            throw SyncError.invalidConfiguration("Remote folder and executable are required")
        }
    }

    public var expandedRoot: URL {
        URL(fileURLWithPath: NSString(string: root).expandingTildeInPath).standardizedFileURL
    }

    public static func load(_ url: URL) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }
}

public enum SyncError: Error, CustomStringConvertible {
    case command([String], String)
    case invalidConfiguration(String)
    case invalidProtocol(String)
    case disconnected

    public var description: String {
        switch self {
        case let .command(arguments, error): return "git \(arguments.joined(separator: " ")): \(error)"
        case let .invalidConfiguration(message), let .invalidProtocol(message): return message
        case .disconnected: return "Peer disconnected"
        }
    }
}

enum Validator {
    static func machine(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty, value != ".", value != "..",
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw SyncError.invalidProtocol("Invalid machine name: \(value)")
        }
    }

    static func project(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
            throw SyncError.invalidProtocol("Invalid project name: \(value)")
        }
    }

    static func sourceRef(_ value: String) throws {
        guard value == "refs/stash" || value.hasPrefix("refs/heads/") || value.hasPrefix("refs/tags/"),
              Git.checkRef(value) else {
            throw SyncError.invalidProtocol("Ref is outside the source allowlist: \(value)")
        }
    }

    static func oid(_ value: String) throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard (value.count == 40 || value.count == 64), value.unicodeScalars.allSatisfy(hex.contains) else {
            throw SyncError.invalidProtocol("Invalid object ID")
        }
    }
}

public struct RefUpdate: Codable, Equatable {
    public let repository: String
    public let sourceRef: String
    public let generation: UInt64
    public let oid: String?
}

struct StoredRef: Codable, Equatable {
    var oid: String?
    var generation: UInt64
}
