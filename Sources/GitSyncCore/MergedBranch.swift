import Foundation

/// GitHub's original PR head, never the squash/rebase result on the base branch.
public struct MergedBranch: Codable, Equatable, Sendable {
    public let id: UUID
    public let repository: String
    public let sourceRepository: String
    public let branch: String
    public let oid: String
    public let baseBranch: String
    public let defaultBranch: String
    public let pullRequest: UInt64
    public let mergedAt: String

    var sourceRef: String { "refs/heads/\(branch)" }

    func validate() throws {
        for name in [repository, sourceRepository] {
            guard Repository.githubURL(forOrigin: "https://github.com/\(name)") != nil,
                  name.split(separator: "/").count == 2,
                  !name.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" }) else {
                throw SyncError.invalidProtocol("Invalid merged PR repository")
            }
        }
        try Validator.sourceRef(sourceRef)
        try Validator.sourceRef("refs/heads/\(baseBranch)")
        try Validator.sourceRef("refs/heads/\(defaultBranch)")
        try Validator.oid(oid)
        guard pullRequest > 0, ISO8601DateFormatter().date(from: mergedAt) != nil else {
            throw SyncError.invalidProtocol("Invalid merged PR identity")
        }
    }
}

public struct MergedBranchBackup: Codable, Equatable, Sendable {
    public let merge: MergedBranch
    public let machine: String
    public let project: String
    /// NUL-delimited config output preserves repeated keys and embedded newlines.
    public let branchConfiguration: String

    public var ref: String {
        "refs/sync/\(Validator.remote(machine))/merged/\(merge.id.uuidString.lowercased())/heads/\(merge.branch)"
    }
}

public enum MergedBranchEligibility: Equatable, Sendable {
    case eligible, deferred, skipped
}

extension Repository {
    public func mergedBranchEligibility(_ merge: MergedBranch) throws -> MergedBranchEligibility {
        try merge.validate()
        let remotes = try githubRemotes()
        let sourceRemotes = remotes.filter { $0.repository == merge.sourceRepository }
        guard placement == .checkedOut,
              !sourceRemotes.isEmpty,
              merge.branch != merge.baseBranch, merge.branch != merge.defaultBranch,
              merge.branch != defaultBranch else { return .skipped }
        for (key, allowed) in [("remote", sourceRemotes.map(\.name)), ("merge", [merge.sourceRef])] {
            let value = String(decoding: try Git.run(["-C", url.path, "config", "--get", "branch.\(merge.branch).\(key)"], successStatuses: [0, 1]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !allowed.contains(value) { return .skipped }
        }
        let refs = try Git.text(["-C", url.path, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", merge.sourceRef])
        let matching = refs.split(separator: "\n").map { $0.split(separator: "\0", omittingEmptySubsequences: false) }
            .first { $0.first == Substring(merge.sourceRef) }
        guard let matching, matching.count == 3, matching[2].isEmpty, matching[1] == Substring(merge.oid) else { return .skipped }
        // Include linked worktrees and in-progress rebase/bisect operations reported by Git.
        let worktrees = try Git.text(["-C", url.path, "worktree", "list", "--porcelain", "-z"])
        if worktrees.split(separator: "\0").contains(Substring("branch \(merge.sourceRef)")) { return .deferred }
        for entry in worktrees.split(separator: "\0") where entry.hasPrefix("worktree ") {
            let path = String(entry.dropFirst("worktree ".count))
            for state in ["rebase-merge/head-name", "rebase-apply/head-name", "BISECT_START"] {
                let file = try Git.text(["-C", path, "rev-parse", "--path-format=absolute", "--git-path", state])
                if FileManager.default.fileExists(atPath: file) {
                    let branch = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    if branch == merge.sourceRef || branch == merge.branch { return .deferred }
                }
            }
        }
        for remote in remotes {
            let head = try Git.text(["-C", url.path, "for-each-ref", "--format=%(symref)", "refs/remotes/\(remote.name)/HEAD"])
            if head == "refs/remotes/\(remote.name)/\(merge.branch)" { return .skipped }
        }
        return .eligible
    }

    public func mergedBranchBackup(_ merge: MergedBranch, machine: String) throws -> MergedBranchBackup {
        try merge.validate()
        try Validator.machine(machine)
        try Validator.project(name)
        // Escape the branch as a literal POSIX ERE, not a user-supplied regex.
        let literal = merge.branch.reduce(into: "") { value, character in
            if ".^$*+?()[]{}|\\".contains(character) { value.append("\\") }
            value.append(character)
        }
        let config = try Git.run(["-C", url.path, "config", "--local", "--null", "--get-regexp", "^branch\\.\(literal)\\."], successStatuses: [0, 1])
        return MergedBranchBackup(merge: merge, machine: machine, project: name,
                                  branchConfiguration: String(decoding: config, as: UTF8.self))
    }

    /// The caller must obtain a matching permanent backup receipt before calling this.
    public func deleteMergedBranch(_ backup: MergedBranchBackup, receipt: MergedBranchBackup) throws -> MergedBranchEligibility {
        guard receipt == backup, backup.project == name else {
            throw SyncError.invalidProtocol("Merged branch backup receipt does not match")
        }
        let eligibility = try mergedBranchEligibility(backup.merge)
        guard eligibility == .eligible else { return eligibility }
        guard try mergedBranchBackup(backup.merge, machine: backup.machine) == backup else { return .skipped }
        // --no-deref also prevents a raced symbolic ref from touching another local branch.
        _ = try Git.run(["-C", url.path, "update-ref", "--no-deref", "-d", backup.merge.sourceRef, backup.merge.oid])
        return .eligible
    }
}

extension BackupIndex {
    /// Pins objects previously received by replication; never trusts an inventory or source-side ACK.
    public static func retainMergedBranch(_ backup: MergedBranchBackup, in root: URL) throws -> MergedBranchBackup {
        try backup.merge.validate()
        try Validator.machine(backup.machine)
        try Validator.project(backup.project)
        guard Git.checkRef(backup.ref) else { throw SyncError.invalidProtocol("Invalid merged backup ref") }
        let url = root.appendingPathComponent(backup.project + ".git")
        guard try Git.text(["-C", url.path, "rev-parse", "--is-bare-repository"]) == "true",
              try Git.text(["-C", url.path, "rev-parse", "--is-shallow-repository"]) == "false" else {
            throw SyncError.invalidConfiguration("Merged branch backup requires a complete bare repository")
        }
        for file in ["objects/info/alternates", "info/grafts"] where FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path) {
            throw SyncError.invalidConfiguration("Merged branch backup must contain its own complete history")
        }
        let environment = ["GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1",
                           "GIT_ALTERNATE_OBJECT_DIRECTORIES": "", "GIT_OBJECT_DIRECTORY": url.appendingPathComponent("objects").path]
        // Explicit traversal also rejects missing promisor objects, which fsck alone permits.
        _ = try Git.run(["-C", url.path, "rev-list", "--quiet", "--objects", "--missing=error", backup.merge.oid], environment: environment)
        // ponytail: full fsck scans this repository; use a targeted integrity check if large backups make cleanup slow.
        // fsck traverses commits, trees and blobs and fails on missing/corrupt reachable objects.
        _ = try Git.run(["-C", url.path, "fsck", "--full", "--no-reflogs", "--no-dangling", backup.merge.oid], environment: environment)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = String(decoding: try encoder.encode(backup), as: UTF8.self)
        let date = ISO8601DateFormatter().date(from: backup.merge.mergedAt)!
        let tag = "object \(backup.merge.oid)\ntype commit\ntag merged-\(backup.merge.id.uuidString.lowercased())\ntagger Gitinuum <backup@gitinuum.local> \(Int(date.timeIntervalSince1970)) +0000\n\n\(metadata)\n"
        let tagOID = String(decoding: try Git.run(["-C", url.path, "-c", "core.fsync=loose-object,reference", "mktag"], input: Data(tag.utf8), environment: environment), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = try Git.text(["-C", url.path, "for-each-ref", "--format=%(objectname)", backup.ref])
        if existing.isEmpty {
            // Git owns the lock and transaction. A concurrent identical request may win; retry is safe.
            _ = try Git.run(["-C", url.path, "-c", "core.fsync=loose-object,reference", "update-ref", backup.ref, tagOID,
                             String(repeating: "0", count: tagOID.count)])
        } else if existing != tagOID {
            throw SyncError.invalidProtocol("Existing merged branch backup differs")
        }
        guard try Git.text(["-C", url.path, "rev-parse", "--verify", backup.ref]) == tagOID,
              try Git.text(["-C", url.path, "cat-file", "tag", tagOID]) == tag.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SyncError.invalidProtocol("Could not verify merged branch backup")
        }
        return backup
    }
}
