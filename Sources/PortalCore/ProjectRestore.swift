import Foundation

/// Explicit, versioned restore into a new checkout; never used by background replication.
public struct ProjectRestoreRequest: Codable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    public let name: String
    public let snapshot: BackupSnapshot
    public let byteCount: Int

    public init(name: String, snapshot: BackupSnapshot, byteCount: Int) {
        self.name = name
        self.snapshot = snapshot
        self.byteCount = byteCount
    }

    public static func receive(from input: FileHandle, to root: URL) throws -> PeerProject {
        let request = try BackupControlConnection.receive(Self.self, from: input)
        guard request.version == currentVersion, request.byteCount >= 0 else {
            throw SyncError.invalidProtocol("Unsupported or invalid project restore request")
        }
        try Validator.project(request.name)
        let temporary = root.appendingPathComponent(".portal-restore-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent("snapshot.bundle")
        guard FileManager.default.createFile(atPath: bundle.path, contents: nil) else {
            throw SyncError.invalidConfiguration("Could not create the temporary backup bundle")
        }
        let output = try FileHandle(forWritingTo: bundle)
        defer { try? output.close() }
        try BackupControlConnection.copy(request.byteCount, from: input, to: output)
        try output.close()
        try BackupIndex.restore(request.name, snapshot: request.snapshot, from: bundle, to: root)
        let repository = Repository(name: request.name, url: root.appendingPathComponent(request.name))
        return PeerProject(name: request.name, placement: repository.placement,
                           defaultBranch: repository.defaultBranch, githubRepositories: repository.githubRepositories,
                           workingChanges: try? repository.workingChanges(), branchTips: try? repository.branchTips())
    }
}
