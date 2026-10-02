import Foundation

/// Progress on the local helper pipe; independent of peer replication and diagnostic logs.
public struct BackupProgress: Codable, Equatable, Sendable {
    public static let version = 1
    public enum Phase: String, Codable, Sendable { case transferring, current, failed }
    public var version: Int
    public let project: String?
    public let phase: Phase
    public let failure: String?

    public init(project: String? = nil, phase: Phase, failure: String? = nil) {
        version = Self.version
        self.project = project
        self.phase = phase
        self.failure = failure
    }

    public func checked() throws -> Self {
        guard version == Self.version else { throw SyncError.invalidProtocol("Unsupported backup progress version") }
        if let project { try Validator.project(project) }
        guard phase == .failed ? failure != nil : project != nil else {
            throw SyncError.invalidProtocol("Incomplete backup progress")
        }
        return self
    }
}
