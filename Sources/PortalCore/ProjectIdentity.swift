import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension Repository {
    /// Each catalog entry owns its identity, including separately named linked worktrees.
    public func projectID(adopting expected: String? = nil) throws -> String {
        if let expected { try Validator.projectID(expected) }
        let path = try Git.text(["-C", url.path, "rev-parse", "--path-format=absolute", "--git-dir"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let descriptor = open(directory.appendingPathComponent("portal-identity.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SyncError.invalidConfiguration("Cannot lock project identity: \(url.path)") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SyncError.invalidConfiguration("Cannot lock project identity") }
        let identity = directory.appendingPathComponent("portal-project-id")
        if FileManager.default.fileExists(atPath: identity.path) {
            let stored = try String(contentsOf: identity, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try Validator.projectID(stored)
            guard expected == nil || expected == stored else {
                throw SyncError.invalidConfiguration("Different projects share the name \(name). Move or explicitly link the intended repository before syncing.")
            }
            return stored
        }
        let id = expected ?? UUID().uuidString.lowercased()
        try Data((id + "\n").utf8).write(to: identity, options: .atomic)
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
