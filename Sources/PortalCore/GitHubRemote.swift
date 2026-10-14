import Foundation

public struct GitHubRemote: Equatable, Sendable {
    public let name: String
    public let repository: String
    let url: String
}

public struct GitHubBranchStatus: Codable, Equatable, Sendable {
    public let branch: String
    public let remoteBranch: String
    public let ahead: Int
    public let behind: Int

    public var title: String {
        switch (ahead, behind) {
        case (0, 0): "Up to date"
        case (_, 0): "\(ahead) ahead"
        case (0, _): "\(behind) behind"
        default: "\(ahead) ahead, \(behind) behind"
        }
    }
}

/// Branch tips and GitHub comparisons from local refs only; never performs network I/O.
public struct RepositoryBranchTips: Codable, Equatable, Sendable {
    public let local: [String: String]
    public let github: [String: String]

    public init(local: [String: String], github: [String: String]) {
        self.local = local
        self.github = github
    }
}

extension Repository {
    public func githubRemotes() throws -> [GitHubRemote] {
        try Git.text(["-C", url.path, "remote"]).split(separator: "\n")
            .sorted { $0 == "origin" && $1 != "origin" }.compactMap { name in
            let name = String(name)
            let origin = try Git.text(["-C", url.path, "config", "--get", "remote.\(name).url"])
            guard let github = Self.githubURL(forOrigin: origin) else { return nil }
            return GitHubRemote(name: name, repository: String(github.path.dropFirst()).lowercased(), url: origin)
        }
    }

    public var githubRepositories: [String] { (try? githubRemotes().map(\.repository)) ?? [] }

    public func branchTips() throws -> RepositoryBranchTips? {
        guard placement == .checkedOut else { return nil }
        let remotes = Set(try githubRemotes().map(\.name))
        let rows = String(decoding: try Git.run(["-C", url.path, "for-each-ref",
            "--format=%(refname)%09%(objectname)%09%(upstream:remotename)%09%(upstream:remoteref)",
            "refs/heads/", "refs/remotes/"]), as: UTF8.self)
            .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let refs = Dictionary(uniqueKeysWithValues: rows.filter { $0.count == 4 }.map { ($0[0], $0[1]) })
        var local: [String: String] = [:], github: [String: String] = [:]
        for row in rows where row.count == 4 && row[0].hasPrefix("refs/heads/") {
            let branch = String(row[0].dropFirst("refs/heads/".count))
            local[branch] = row[1]
            let remote = row[2].isEmpty ? "origin" : row[2]
            let upstream = row[3].isEmpty ? row[0] : row[3]
            guard remotes.contains(remote), upstream.hasPrefix("refs/heads/") else { continue }
            github[branch] = refs["refs/remotes/" + remote + "/" + upstream.dropFirst("refs/heads/".count)]
        }
        return RepositoryBranchTips(local: local, github: github)
    }

    /// Compare only locally known refs. Existing push-triggered fetches refresh them.
    func githubBranchStatus(head: String?, headOID: String?) throws -> GitHubBranchStatus? {
        guard let head, let headOID, let githubURL else { return nil }
        let upstream = try Git.text(["-C", url.path, "for-each-ref",
            "--format=%(upstream:remotename)%09%(upstream:remoteref)", "refs/heads/" + head])
            .split(separator: "\t", omittingEmptySubsequences: false)
        let remoteName = upstream.first.map(String.init) ?? ""
        let remote = try githubRemotes().first { $0.name == (remoteName.isEmpty ? "origin" : remoteName) }
        guard let remote, Self.githubURL(forOrigin: remote.url) == githubURL else { return nil }
        let branchRef = upstream.count == 2 && !upstream[1].isEmpty ? String(upstream[1]) : "refs/heads/" + head
        guard branchRef.hasPrefix("refs/heads/") else { return nil }
        let remoteBranch = remote.name + "/" + branchRef.dropFirst("refs/heads/".count)
        guard let remoteOID = try? Git.text(["-C", url.path, "rev-parse", "--verify",
                                             "refs/remotes/" + remoteBranch + "^{commit}"]) else { return nil }
        let counts = try Git.text(["-C", url.path, "rev-list", "--left-right", "--count",
                                   headOID + "..." + remoteOID, "--"]).split(whereSeparator: \.isWhitespace)
        guard counts.count == 2, let ahead = Int(counts[0]), let behind = Int(counts[1]) else { return nil }
        return GitHubBranchStatus(branch: head, remoteBranch: remoteBranch, ahead: ahead, behind: behind)
    }

    /// Fetch tracking branches and origin tags with explicit destinations, never remote.*.fetch.
    public func fetchGitHub(_ repository: String, peerMachines: [String]) throws {
        let access = try ProjectAccess(root: url.deletingLastPathComponent(), names: [name])
        defer { withExtendedLifetime(access) {} }
        guard placement == .checkedOut else {
            throw SyncError.invalidConfiguration("GitHub fetch requires a local checkout")
        }
        for remote in try githubRemotes() where remote.repository == repository.lowercased() {
            let prefix = "refs/remotes/\(remote.name)/"
            let peers = peerMachines.map { "refs/remotes/\(Validator.remote($0))/" }
            guard Git.checkRef(prefix + "branch"),
                  !peers.contains(where: { prefix.hasPrefix($0) || $0.hasPrefix(prefix) }),
                  (try? Git.text(["-C", url.path, "config", "--bool", "--get", "remote.\(remote.name).mirror"])) != "true" else {
                throw SyncError.invalidConfiguration("Unsafe GitHub remote namespace: \(remote.name)")
            }
            let refs = try Git.text(["-C", url.path, "for-each-ref", "--format=%(refname) %(symref)", prefix])
            for ref in refs.split(separator: "\n") {
                let fields = ref.split(separator: " ")
                if fields.count > 1 && !fields[1].hasPrefix(prefix) {
                    throw SyncError.invalidConfiguration("GitHub tracking ref points outside its namespace")
                }
            }
            // Use the URL, not the remote name: mirror, tag and fetch configuration cannot add destinations.
            _ = try Git.run(["-C", url.path, "-c", "fetch.pruneTags=false", "fetch",
                             "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules",
                             "--no-auto-maintenance", "--prune", "--refmap=", "--", remote.url,
                             "+refs/heads/*:\(prefix)*"], environment: ["GIT_TERMINAL_PROMPT": "0"])
            if remote.name == "origin" {
                let symrefs = try Git.text(["-C", url.path, "for-each-ref", "--format=%(symref)", "refs/tags/"])
                guard symrefs.isEmpty else {
                    throw SyncError.invalidConfiguration("GitHub tag destination contains symbolic refs")
                }
                // Tags are never forced or pruned, even when local fetch configuration requests it.
                _ = try Git.run(["-C", url.path, "-c", "fetch.pruneTags=false", "fetch",
                                 "--no-tags", "--no-prune", "--no-write-fetch-head", "--no-recurse-submodules",
                                 "--no-auto-maintenance", "--refmap=", "--", remote.url,
                                 "refs/tags/*:refs/tags/*"], environment: ["GIT_TERMINAL_PROMPT": "0"])
            }
        }
    }
}
