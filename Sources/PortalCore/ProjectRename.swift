import Foundation
import PortalWatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Held only across Portal operations, never across ordinary user Git commands.
public final class ProjectAccess {
    private var descriptor: Int32 = -1
    public let records: [ProjectRename.Record]

    public init(root: URL, names: [String] = [], expected: [ProjectRename.Record]? = nil,
                exclusive: Bool = false, waitForIdle: TimeInterval = 0) throws {
        descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SyncError.invalidConfiguration("Cannot lock projects folder: \(root.path)") }
        let deadline = ProcessInfo.processInfo.systemUptime + waitForIdle
        while flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            let failure = errno
            guard (failure == EWOULDBLOCK || failure == EAGAIN || failure == EINTR),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                close(descriptor)
                descriptor = -1
                throw SyncError.invalidConfiguration("Portal is busy in \(root.path). Try rename again when idle.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        do {
            records = try ProjectRename.records(in: root)
            if let expected, expected != records {
                throw SyncError.invalidConfiguration("Project names changed; reconnect before syncing.")
            }
            if !exclusive {
                for name in names {
                    try Validator.project(name)
                    if ProjectRename.isRetiredOrSuspended(name, records: records) {
                        throw SyncError.invalidConfiguration("\(name) is suspended or retired by a rename. Inspect \(ProjectRename.journal(in: root).path).")
                    }
                }
            }
        } catch { close(descriptor); descriptor = -1; throw error }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

public enum ProjectRename {
    public enum Step: String, Codable, Sendable { case preflight, prepare, move, finish, suspend }
    public enum Progress: String, Codable, Sendable { case checking, cancelling, renaming }

    /// Cancellation and the first journal write must agree on one boundary.
    public final class Operation: @unchecked Sendable {
        public let id: UUID
        private let lock = NSLock()
        private var state: Progress = .checking
        private let changed: @Sendable () -> Void

        public init(id: UUID, changed: @escaping @Sendable () -> Void = {}) {
            self.id = id
            self.changed = changed
        }

        public var progress: Progress { lock.withLock { state } }

        public func cancel() {
            lock.withLock { if state == .checking { state = .cancelling } }
            changed()
        }

        public func checkCancellation() throws {
            if progress == .cancelling { throw CancellationError() }
        }

        fileprivate func begin() throws {
            try lock.withLock {
                if state == .cancelling { throw CancellationError() }
                state = .renaming
            }
            changed()
        }
    }
    public struct Record: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let old: String
        public let new: String
        public var previousRenames: [UUID]?
        public var moved = false
        public var complete = false
        public init(id: UUID = UUID(), old: String, new: String, previousRenames: [UUID] = []) {
            self.id = id
            self.old = old.precomposedStringWithCanonicalMapping
            self.new = new.precomposedStringWithCanonicalMapping
            self.previousRenames = previousRenames
        }
    }

    public static func validate(_ record: Record) throws {
        try Validator.project(record.old); try Validator.project(record.new)
        guard !record.new.hasPrefix("."), !record.old.contains("\u{1f}"), !record.new.contains("\u{1f}"),
              record.old.localizedCaseInsensitiveCompare(record.new) != .orderedSame else {
            throw SyncError.invalidConfiguration("Choose a different name; case-only renames are not supported.")
        }
    }

    public static func journal(in root: URL) -> URL { root.appendingPathComponent(".portal-renames.json") }

    public static func records(in root: URL) throws -> [Record] {
        let url = journal(in: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: url))
    }

    public static func resolved(_ name: String, records: [Record]) -> String {
        records.reduce(name) { result, record in record.complete && result == record.old ? record.new : result }
    }

    public static func revision(_ records: [Record]) throws -> [UUID] {
        guard records.allSatisfy(\.complete) else {
            throw SyncError.invalidConfiguration("A project rename requires completion or manual recovery.")
        }
        return records.map(\.id)
    }

    public static func pending(_ records: [Record], after applied: [UUID]) throws -> [Record] {
        let completed = records.filter(\.complete)
        guard Array(completed.prefix(applied.count).map(\.id)) == applied else {
            throw SyncError.invalidConfiguration("Project naming history changed or was reset; inspect the rename journals before syncing.")
        }
        return Array(completed.dropFirst(applied.count))
    }

    public static func isRetiredOrSuspended(_ name: String, records: [Record]) -> Bool {
        guard let latest = records.last(where: { $0.old == name || $0.new == name }) else { return false }
        return !latest.complete || latest.old == name
    }

    /// Backup callers perform their metadata write while this exclusive lock is held.
    public static func perform(_ step: Step, record: Record, in root: URL, bare: Bool = false,
                               metadata: () throws -> Void = {}) throws {
        try validate(record)
        // A background write may finish shortly after the initiating host stops sync.
        let access = try ProjectAccess(root: root, exclusive: true, waitForIdle: 10)
        defer { withExtendedLifetime(access) {} }
        var records = access.records
        let source = root.appendingPathComponent(record.old + (bare ? ".git" : ""))
        let target = root.appendingPathComponent(record.new + (bare ? ".git" : ""))
        switch step {
        case .preflight, .prepare:
            guard FileManager.default.isWritableFile(atPath: root.path) else {
                throw SyncError.invalidConfiguration("Rename requires write access to the projects folder: \(root.path)")
            }
            guard try revision(records) == (record.previousRenames ?? []) else {
                throw SyncError.invalidConfiguration("Project naming history differs in \(root.path). Every host must acknowledge the earlier renames first.")
            }
            let destination = records.last(where: { $0.old == record.new || $0.new == record.new })
            guard !records.contains(where: { $0.id == record.id }),
                  !isRetiredOrSuspended(record.old, records: records),
                  destination?.new != record.new, !exists(target) else {
                throw SyncError.invalidConfiguration("Rename conflicts with an existing name or unfinished rename in \(root.path).")
            }
            if exists(source) { try validateRepository(source, bare: bare) }
            if step == .preflight { return }
            records.append(Record(id: record.id, old: record.old, new: record.new,
                                  previousRenames: record.previousRenames ?? []))
        case .move, .finish, .suspend:
            guard let i = records.firstIndex(where: { $0.id == record.id && $0.old == record.old && $0.new == record.new }) else {
                throw SyncError.invalidConfiguration("Rename was not prepared in \(root.path).")
            }
            if step == .move {
                guard !records[i].moved, !exists(target) else {
                    throw SyncError.invalidConfiguration("Rename has already moved or the destination exists: \(target.path)")
                }
                if exists(source) {
                    try validateRepository(source, bare: bare)
                    guard portal_rename_exclusive(source.path, target.path) == 0 else {
                        throw SyncError.invalidConfiguration("Cannot rename \(source.path): \(String(cString: strerror(errno)))")
                    }
                }
                try metadata()
                records[i].moved = true
            } else if step == .finish {
                guard records[i].moved else { throw SyncError.invalidConfiguration("Rename has not moved yet.") }
                records[i].complete = true
            } else { records[i].complete = false }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: journal(in: root), options: .atomic)
    }

    private static func exists(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil
    }

    private static func validateRepository(_ url: URL, bare: Bool) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try Git.text(["-C", url.path, "rev-parse", "--is-bare-repository"]) == (bare ? "true" : "false") else {
            throw SyncError.invalidConfiguration("Not a standalone repository: \(url.path)")
        }
        if !bare {
            let git = url.appendingPathComponent(".git")
            let values = try git.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try Git.text(["-C", url.path, "worktree", "list", "--porcelain"])
                    .components(separatedBy: "\n").filter({ $0.hasPrefix("worktree ") }).count == 1 else {
                throw SyncError.invalidConfiguration("Rename does not support linked worktrees: \(url.path)")
            }
        }
    }
}

extension ProjectRename {
    public struct Target {
        public let name: String
        public let perform: (Step) throws -> Void
        public init(name: String, perform: @escaping (Step) throws -> Void) {
            self.name = name
            self.perform = perform
        }
    }

    /// The caller orders the backup before the working repositories.
    public static func coordinate(_ targets: [Target], operation: Operation? = nil) throws {
        // Reject incompatible or unwritable peers before suspending any root.
        for target in targets {
            try operation?.checkCancellation()
            do { try target.perform(.preflight) }
            catch { throw SyncError.invalidConfiguration("Rename preflight failed on \(target.name): \(error). No rename was started.") }
        }
        try operation?.begin()
        var attempted = Set<Int>()
        var status = Array(repeating: "unchanged", count: targets.count)
        do {
            for step in [Step.prepare, .move, .finish] {
                for (i, target) in targets.enumerated() {
                    attempted.insert(i)
                    if step == .move { status[i] = "unknown (move acknowledgement pending)" }
                    try target.perform(step)
                    if step == .move { status[i] = "renamed (or no copy present)" }
                }
            }
        } catch {
            var suspensionFailures: [String] = []
            for i in attempted.sorted() {
                do { try targets[i].perform(.suspend) }
                catch { suspensionFailures.append(targets[i].name) }
            }
            let report = zip(targets, status).map { "\($0.name): \($1)" }.joined(separator: "\n")
            let warning = suspensionFailures.isEmpty ? "Both names remain suspended."
                : "Could not confirm suspension on: " + suspensionFailures.joined(separator: ", ")
            throw SyncError.invalidConfiguration("Rename stopped: \(error)\n\(report)\n\(warning)\nInspect the folders and .portal-renames.json on every host before manually completing the rename. No rollback was attempted.")
        }
    }
}
