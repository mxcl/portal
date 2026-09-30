import Foundation
import GitSyncWatch

/// An invalidation stream, separate from the Git replication protocol. Every
/// connection starts with a catch-up event; no ordering state survives reconnects.
public struct ProjectChange: Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public init(version: Int = currentVersion) { self.version = version }
    public func checked() throws -> Self {
        guard version == Self.currentVersion else {
            throw SyncError.invalidProtocol("Unsupported project watch version: \(version)")
        }
        return self
    }
}

/// Owned by the blocking watch command. The OS keeps events queued during scans.
final class ProjectChangeWatcher {
    private let observer: OpaquePointer
    init(root: URL) throws {
        guard let observer = git_sync_observer_create() else {
            throw SyncError.invalidConfiguration("Could not create filesystem observer")
        }
        self.observer = observer
        try add(root)
    }
    deinit { git_sync_observer_destroy(observer) }
    func add(_ url: URL) throws {
        guard git_sync_observer_add(observer, url.resolvingSymlinksInPath().path) == 0 else {
            throw SyncError.invalidConfiguration("Could not watch \(url.path); check filesystem watch limits and permissions")
        }
    }
    func wait(milliseconds: Int32 = -1) throws -> Bool {
        let result = git_sync_observer_wait(observer, milliseconds)
        guard result >= 0 else { throw SyncError.invalidConfiguration("Filesystem observation failed; reconnect to rescan") }
        return result != 0
    }
}

extension Runner {
    public static func watchProjects(root: URL, version: Int, output: FileHandle = .standardOutput) throws {
        _ = try ProjectChange(version: version).checked()
        let watcher = try ProjectChangeWatcher(root: root)
        while true {
            // Linked worktrees can have metadata outside the watched root. Add
            // watches before publishing, keeping existing watches alive throughout.
            for repository in try Repository.discover(in: root) {
                if let common = repository.commonDirectory { try watcher.add(common) }
            }
            try BackupControlConnection.send(ProjectChange(), to: output)
            _ = try watcher.wait()
            // Coalesce a burst, without scheduling any idle scans. Bound the drain
            // so a continuously changing checkout still publishes updates.
            for _ in 0..<4 {
                if try !watcher.wait(milliseconds: 125) { break }
            }
        }
    }

    public static func projectWatchProcess(_ configuration: Configuration) throws -> Process {
        try configuration.validate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=2", "-T", "--", configuration.peer,
            remoteCommand(configuration.remoteExecutable, ["watch-projects", "--root", configuration.remoteRoot,
                "--watch-version", String(ProjectChange.currentVersion)])]
        return process
    }
}
