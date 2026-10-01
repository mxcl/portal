import Foundation

/// Separate from replication and backup control: old peers can keep syncing.
public struct RepositorySearchReply: Codable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let matches: [RepositorySearchMatch]

    public init(matches: [RepositorySearchMatch], version: Int = currentVersion) {
        self.version = version
        self.matches = matches
    }

    public func checked() throws -> [RepositorySearchMatch] {
        guard version == Self.currentVersion else {
            throw SyncError.invalidProtocol("Unsupported search version: \(version)")
        }
        return matches
    }
}

public struct RepositorySearchMatch: Codable, Equatable, Sendable {
    public let reference: RepositoryReference?
    public let commit: RepositoryCommit
}

public enum PaletteMatch {
    public static func rank(_ name: String, query: String) -> Int? {
        let name = name.lowercased(), query = query.lowercased()
        if query.isEmpty || name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.contains(query) { return 2 }
        var remaining = name[...]
        for character in query {
            guard let index = remaining.firstIndex(of: character) else { return nil }
            remaining = remaining[remaining.index(after: index)...]
        }
        return 3
    }

    public static func isSHA(_ query: String) -> Bool {
        (4...64).contains(query.utf8.count) && query.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

extension Repository {
    public func commit(at oid: String) throws -> RepositoryCommit {
        try Validator.oid(oid)
        let resolved = try Git.text(["-C", url.path, "rev-parse", "--verify", oid + "^{commit}"])
        guard let commit = try snapshot(limit: 1, references: [], revisions: [resolved, "--"], head: nil).commits.first else {
            throw SyncError.invalidConfiguration("Commit is unavailable: \(oid)")
        }
        return commit
    }

    public func search(_ query: String, references supplied: [RepositoryReference]? = nil) throws -> RepositorySearchReply {
        guard !query.isEmpty else { return RepositorySearchReply(matches: []) }
        let references = try supplied ?? referenceSnapshot()
        var matches: [RepositorySearchMatch] = []
        var commits: [String: RepositoryCommit] = [:]
        for reference in references {
            let parts = reference.fullName.split(separator: "/", maxSplits: 4)
            let isTag = reference.fullName.hasPrefix("refs/tags/") ||
                (parts.count == 5 && parts[1] == "sync" && parts[3] == "tags")
            let isBranch = reference.fullName.hasPrefix("refs/heads/") ||
                (reference.fullName.hasPrefix("refs/remotes/") && !reference.fullName.hasSuffix("/HEAD"))
            guard isTag || isBranch else { continue }
            guard PaletteMatch.rank(reference.name, query: query) != nil else { continue }
            // Tags may point to trees or blobs; only commit targets are navigable.
            guard let commit = commits[reference.oid] ?? (try? self.commit(at: reference.oid)) else { continue }
            commits[reference.oid] = commit
            matches.append(RepositorySearchMatch(reference: reference, commit: commit))
        }
        if PaletteMatch.isSHA(query) {
            let candidates = try Git.text(["-C", url.path, "rev-parse", "--disambiguate=" + query.lowercased()])
            for oid in candidates.split(separator: "\n").map(String.init) {
                guard try Git.text(["-C", url.path, "cat-file", "-t", oid]) == "commit" else { continue }
                let commit = try commits[oid] ?? self.commit(at: oid)
                matches.append(RepositorySearchMatch(reference: nil, commit: commit))
            }
        }
        return RepositorySearchReply(matches: matches)
    }
}
