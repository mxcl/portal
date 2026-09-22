import Foundation

public struct GitHubRemote: Equatable, Sendable {
    public let name: String
    public let repository: String
    let url: String
}

extension Repository {
    public func githubRemotes() throws -> [GitHubRemote] {
        try Git.text(["-C", url.path, "remote"]).split(separator: "\n").compactMap { name in
            let name = String(name)
            let origin = try Git.text(["-C", url.path, "config", "--get", "remote.\(name).url"])
            guard let github = Self.githubURL(forOrigin: origin) else { return nil }
            return GitHubRemote(name: name, repository: String(github.path.dropFirst()).lowercased(), url: origin)
        }
    }

    public var githubRepositories: [String] { (try? githubRemotes().map(\.repository)) ?? [] }

    /// Only this remote's branch tracking namespace is writable. Never trust remote.*.fetch.
    public func fetchGitHub(_ repository: String, peerMachines: [String]) throws {
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
        }
    }
}
