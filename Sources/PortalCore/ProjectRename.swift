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
                exclusive: Bool = false) throws {
        descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SyncError.invalidConfiguration("Cannot lock projects folder: \(root.path)") }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw SyncError.invalidConfiguration("Portal is busy in \(root.path). Try rename again when idle.")
        }
        do {
            records = try ProjectRename.records(in: root)
            if let expected, expected != records {
                throw SyncError.invalidConfiguration("Project names changed; reconnect before syncing.")
            }
            if !exclusive {
                for name in names {
                    try Validator.project(name)
                    if records.contains(where: { $0.old == name || ($0.new == name && !$0.complete) }) {
                        throw SyncError.invalidConfiguration("\(name) is suspended or retired by a rename. Inspect \(ProjectRename.journal(in: root).path).")
                    }
                }
            }
        } catch { close(descriptor); descriptor = -1; throw error }
    }

    deinit { if descriptor >= 0 { close(descriptor) } }
}

public enum ProjectRename {
    public enum Step: String, Codable, Sendable { case prepare, move, finish, suspend }
    public struct Record: Codable, Equatable, Sendable {
        public let id: UUID
        public let old: String
        public let new: String
        public var moved = false
        public var complete = false
        public init(id: UUID = UUID(), old: String, new: String) {
            self.id = id
            self.old = old.precomposedStringWithCanonicalMapping
            self.new = new.precomposedStringWithCanonicalMapping
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

    /// Backup callers perform their metadata write while this exclusive lock is held.
    public static func perform(_ step: Step, record: Record, in root: URL, bare: Bool = false,
                               metadata: () throws -> Void = {}) throws {
        try validate(record)
        let access = try ProjectAccess(root: root, exclusive: true)
        defer { withExtendedLifetime(access) {} }
        var records = access.records
        let source = root.appendingPathComponent(record.old + (bare ? ".git" : ""))
        let target = root.appendingPathComponent(record.new + (bare ? ".git" : ""))
        switch step {
        case .prepare:
            guard !records.contains(where: { !$0.complete || $0.old == record.old || $0.old == record.new || $0.new == record.new }),
                  !exists(target) else {
                throw SyncError.invalidConfiguration("Rename conflicts with an existing name or unfinished rename in \(root.path).")
            }
            if exists(source) { try validateRepository(source, bare: bare) }
            records.append(Record(id: record.id, old: record.old, new: record.new))
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
    public static func coordinate(_ targets: [Target]) throws {
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
