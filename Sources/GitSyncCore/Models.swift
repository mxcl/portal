import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

public enum SyncProtocol {
    public static let version = 5
}

public struct Configuration: Codable, Equatable, Sendable {
    public static let defaultRemoteExecutable = "/Applications/Gitinuum.app/Contents/Resources/gitinuumd"

    public static var defaultMachine: String {
        #if canImport(SystemConfiguration)
        if let name = SCDynamicStoreCopyComputerName(nil, nil) {
            let name = sanitizedMachine(name as String)
            if !name.isEmpty { return name }
        }
        #endif
        let name = sanitizedMachine(ProcessInfo.processInfo.hostName)
        return name.isEmpty ? "machine" : name
    }

    static func sanitizedMachine(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let name = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(name).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
    }

    public var root: String
    public var machine: String
    public var peer: String
    public var remoteRoot: String
    public var remoteExecutable: String
    public var repositories: [String]?
    public var remoteMachine: String?
    public var remoteState: String?
    public var remoteReceiveOnly: Bool?
    public var syncCheckouts: Bool?

    public init(root: String, machine: String, peer: String, remoteRoot: String,
                remoteExecutable: String = Configuration.defaultRemoteExecutable,
                repositories: [String]? = nil, remoteMachine: String? = nil,
                remoteState: String? = nil, remoteReceiveOnly: Bool? = nil,
                syncCheckouts: Bool? = nil) {
        self.root = root
        self.machine = machine
        self.peer = peer
        self.remoteRoot = remoteRoot
        self.remoteExecutable = remoteExecutable
        self.repositories = repositories
        self.remoteMachine = remoteMachine
        self.remoteState = remoteState
        self.remoteReceiveOnly = remoteReceiveOnly
        self.syncCheckouts = syncCheckouts
    }

    public func validate() throws {
        guard FileManager.default.fileExists(atPath: expandedRoot.path) else {
            throw SyncError.invalidConfiguration("Source folder does not exist: \(root)")
        }
        try Validator.machine(machine)
        guard !peer.isEmpty, !peer.hasPrefix("-") else {
            throw SyncError.invalidConfiguration("Invalid SSH peer")
        }
        guard !remoteExecutable.isEmpty, remoteReceiveOnly == true || !remoteRoot.isEmpty else {
            throw SyncError.invalidConfiguration("Remote folder and executable are required")
        }
        guard remoteState?.isEmpty != true else {
            throw SyncError.invalidConfiguration("Remote state path is required")
        }
        for repository in repositories ?? [] { try Validator.project(repository) }
        if let remoteMachine { try Validator.machine(remoteMachine) }
    }

    public var expandedRoot: URL {
        URL(fileURLWithPath: NSString(string: root).expandingTildeInPath).standardizedFileURL
    }

    public static func load(_ url: URL) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }
}

public struct PeerRepositoryLocation: Equatable, Sendable {
    public let machine: String
    public let sshTarget: String
    public let root: String

    public init(machine: String, sshTarget: String, root: String) {
        self.machine = machine
        self.sshTarget = sshTarget
        self.root = root
    }

    func validate() throws {
        try Validator.machine(machine)
        guard !sshTarget.isEmpty, !sshTarget.hasPrefix("-"), !root.isEmpty else {
            throw SyncError.invalidConfiguration("Invalid peer repository location")
        }
    }

    var remoteName: String {
        Validator.remote(machine)
    }

    func url(for repository: String) throws -> String {
        try validate()
        try Validator.project(repository)
        return "\(sshTarget):\(root.hasSuffix("/") ? root : root + "/")\(repository)"
    }
}

public struct PeerInspection: Codable, Equatable, Sendable {
    public let version: Int
    public let machine: String
    public let repositories: [String]
    public let projects: [PeerProject]?

    public init(version: Int, machine: String, repositories: [String], projects: [PeerProject]? = nil) {
        self.version = version
        self.machine = machine
        self.repositories = repositories
        self.projects = projects
    }
}

public enum ProjectPlacement: String, Codable, Equatable, Sendable {
    case checkedOut
    case mirrored
    case notPresent
    case unknown
}

public struct PeerProject: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let placement: ProjectPlacement
    public let defaultBranch: String?

    public init(name: String, placement: ProjectPlacement, defaultBranch: String? = nil) {
        self.name = name
        self.placement = placement
        self.defaultBranch = defaultBranch
    }
}

public struct SyncHost: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var machine: String
    public var displayName: String?
    public var peer: String
    public var root: String
    public var executable: String

    public var name: String { displayName ?? machine }

    public init(id: UUID = UUID(), machine: String, displayName: String? = nil, peer: String, root: String,
                executable: String = Configuration.defaultRemoteExecutable) {
        self.id = id
        self.machine = machine
        self.displayName = displayName
        self.peer = peer
        self.root = root
        self.executable = executable
    }
}

public struct SyncFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public var isLocal: Bool
    public var hosts: Set<UUID>
    public var availableLocally: Bool
    public var availableHosts: Set<UUID>

    public init(name: String, isLocal: Bool = false, hosts: Set<UUID> = [],
                availableLocally: Bool = false, availableHosts: Set<UUID> = []) {
        self.name = name.precomposedStringWithCanonicalMapping
        self.isLocal = isLocal
        self.hosts = hosts
        self.availableLocally = availableLocally
        self.availableHosts = availableHosts
    }
}

public struct BackupConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var hostID: UUID
    public var root: String

    public init(id: UUID = UUID(), hostID: UUID, root: String = "") {
        self.id = id
        self.hostID = hostID
        self.root = root
    }
}

public struct BackupDestinationConfiguration: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var root: String

    public init(id: UUID = UUID(), root: String) {
        self.id = id
        self.root = root
    }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var root: String
    public var machine: String
    public var hosts: [SyncHost]
    public var folders: [SyncFolder]
    public var backup: BackupConfiguration?
    public var backupDestination: BackupDestinationConfiguration?
    public var syncCheckouts: Bool?

    public init(root: String, machine: String, hosts: [SyncHost] = [], folders: [SyncFolder] = [],
                backup: BackupConfiguration? = nil,
                backupDestination: BackupDestinationConfiguration? = nil,
                syncCheckouts: Bool? = nil) {
        self.root = root
        self.machine = machine
        self.hosts = hosts
        self.folders = folders
        self.backup = backup
        self.backupDestination = backupDestination
        self.syncCheckouts = syncCheckouts
    }

    public mutating func discoverLocal(_ names: [String]) throws {
        let normalized = try validatedNames(names)
        let found = Set(normalized)
        for index in folders.indices {
            folders[index].availableLocally = found.contains(folders[index].name)
        }
        for name in normalized where !folders.contains(where: { $0.name == name }) {
            folders.append(SyncFolder(name: name, isLocal: true, availableLocally: true))
        }
        folders.removeAll { !$0.availableLocally && $0.availableHosts.isEmpty }
        folders.sort { $0.name < $1.name }
    }

    @discardableResult
    public mutating func addHost(_ host: SyncHost, repositories: [String]) throws -> [String] {
        try Validator.machine(host.machine)
        guard !host.peer.isEmpty, !host.peer.hasPrefix("-") else {
            throw SyncError.invalidConfiguration("Invalid SSH peer")
        }
        guard !host.root.isEmpty, !host.executable.isEmpty else {
            throw SyncError.invalidConfiguration("Remote folder and executable are required")
        }
        guard host.machine != machine else {
            throw SyncError.invalidConfiguration("A host cannot use this Mac's machine name")
        }
        guard !hosts.contains(where: { $0.peer == host.peer || $0.machine == host.machine }) else {
            throw SyncError.invalidConfiguration("That host is already added")
        }
        let names = try validatedNames(repositories)
        hosts.append(host)
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for name in names {
            if let index = folders.firstIndex(where: { $0.name == name }) {
                folders[index].hosts.insert(host.id)
                folders[index].availableHosts.insert(host.id)
            } else {
                folders.append(SyncFolder(name: name, hosts: [host.id], availableHosts: [host.id]))
            }
        }
        folders.sort { $0.name < $1.name }
        return folders.filter { $0.availableLocally && $0.availableHosts.contains(host.id) }.map(\.name)
    }

    public mutating func updateHostIdentity(_ id: UUID, machine: String) throws {
        try Validator.machine(machine)
        guard machine != self.machine else {
            throw SyncError.invalidConfiguration("A host cannot use this Mac's machine name")
        }
        guard !hosts.contains(where: { $0.id != id && $0.machine == machine }) else {
            throw SyncError.invalidConfiguration("That host is already added")
        }
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].machine = machine
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public mutating func renameHost(_ id: UUID, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SyncError.invalidConfiguration("Host name cannot be empty")
        }
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts[index].displayName = name == hosts[index].machine ? nil : name
        hosts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public mutating func removeHost(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        if backup?.hostID == id { backup = nil }
        for index in folders.indices {
            folders[index].hosts.remove(id)
            folders[index].availableHosts.remove(id)
        }
        folders.removeAll { !$0.availableLocally && $0.availableHosts.isEmpty }
    }

    public func repositories(for hostID: UUID) -> [String] {
        folders.filter { $0.isLocal && $0.hosts.contains(hostID) }.map(\.name).sorted()
    }

    public func backupHost() throws -> SyncHost? {
        guard let backup else { return nil }
        guard let host = hosts.first(where: { $0.id == backup.hostID }) else {
            throw SyncError.invalidConfiguration("Choose an existing host for backups.")
        }
        return host
    }

    public func validatedBackupDestination() throws -> URL? {
        guard let backupDestination else { return nil }
        guard !backupDestination.root.isEmpty else {
            throw SyncError.invalidConfiguration("Choose a folder for received backups.")
        }
        let destination = NSString(string: backupDestination.root).standardizingPath
        guard destination != NSString(string: root).standardizingPath else {
            throw SyncError.invalidConfiguration("The backup destination must differ from this Mac’s projects folder.")
        }
        return URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath).standardizedFileURL
    }

    private func validatedNames(_ names: [String]) throws -> [String] {
        try names.map {
            let name = $0.precomposedStringWithCanonicalMapping
            try Validator.project(name)
            return name
        }
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
    static func remote(_ machine: String) -> String {
        machine.lowercased().split { $0 == "." || $0 == "_" || $0 == "-" }.joined(separator: "-")
    }

    static func machine(_ value: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !value.isEmpty, value != ".", value != "..",
              value.unicodeScalars.allSatisfy(allowed.contains),
              value.contains(where: { $0.isLetter || $0.isNumber }) else {
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

    static func epoch(_ value: String) throws {
        guard UUID(uuidString: value) != nil else {
            throw SyncError.invalidProtocol("Invalid source epoch")
        }
    }
}

public struct RefUpdate: Codable, Equatable {
    public let repository: String
    public let sourceRef: String
    public let generation: UInt64
    public let oid: String?
    public let cleanCheckout: Bool?

    public init(repository: String, sourceRef: String, generation: UInt64, oid: String?,
                cleanCheckout: Bool? = nil) {
        self.repository = repository
        self.sourceRef = sourceRef
        self.generation = generation
        self.oid = oid
        self.cleanCheckout = cleanCheckout
    }
}

struct StoredRef: Codable, Equatable {
    var oid: String?
    var generation: UInt64
}
