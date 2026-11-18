import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension Repository {
    /// Local Git metadata survives moves and is shared by linked worktrees.
    public func projectID(adopting expected: String? = nil) throws -> String {
        if let expected { try Validator.projectID(expected) }
        guard let commonDirectory else { throw SyncError.invalidConfiguration("Missing Git directory: \(url.path)") }
        let descriptor = open(commonDirectory.appendingPathComponent("portal-identity.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SyncError.invalidConfiguration("Cannot lock project identity: \(url.path)") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SyncError.invalidConfiguration("Cannot lock project identity") }
        let stored = String(decoding: try Git.run(["-C", url.path, "config", "--local", "--get", "portal.projectID"], successStatuses: [0, 1]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty {
            try Validator.projectID(stored)
            guard expected == nil || expected == stored else {
                throw SyncError.invalidConfiguration("Different projects share the name \(name). Move or explicitly link the intended repository before syncing.")
            }
            return stored
        }
        let id = expected ?? UUID().uuidString.lowercased()
        _ = try Git.run(["-C", url.path, "config", "--local", "portal.projectID", id])
        return id
    }
}

extension Validator {
    public static func projectID(_ value: String) throws {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else {
            throw SyncError.invalidProtocol("Invalid project UUID: \(value)")
        }
    }
}
