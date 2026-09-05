import Foundation

public struct RepositoryReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fullName }
    public let fullName: String
    public let oid: String

    public init(fullName: String, oid: String) {
        self.fullName = fullName
        self.oid = oid
    }

    public var name: String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/", "refs/sync/"] {
            if fullName.hasPrefix(prefix) { return String(fullName.dropFirst(prefix.count)) }
        }
        return fullName
    }
}

public struct RepositoryCommit: Codable, Equatable, Identifiable, Sendable {
    public var id: String { oid }
    public let oid: String
    public let parents: [String]
    public let author: String
    public let date: Date
    public let message: String

    public init(oid: String, parents: [String], author: String, date: Date, message: String) {
        self.oid = oid
        self.parents = parents
        self.author = author
        self.date = date
        self.message = message
    }

    public var subject: String { message.split(whereSeparator: \.isNewline).first.map(String.init) ?? oid }
}

public struct RepositorySnapshot: Codable, Equatable, Sendable {
    public let commits: [RepositoryCommit]
    public let references: [RepositoryReference]
    public let head: String?
    public let branches: [String]

    public init(commits: [RepositoryCommit], references: [RepositoryReference], head: String?, branches: [String]) {
        self.commits = commits
        self.references = references
        self.head = head
        self.branches = branches
    }
}

public struct RepositoryReadme: Codable, Equatable, Sendable {
    public let markdown: String
    public let source: String

    public init(markdown: String, source: String) {
        self.markdown = markdown
        self.source = source
    }
}

public struct RepositoryContent: Codable, Equatable, Sendable {
    public let snapshot: RepositorySnapshot
    public let readme: RepositoryReadme?
    public let githubURL: URL?

    public init(snapshot: RepositorySnapshot, readme: RepositoryReadme?, githubURL: URL?) {
        self.snapshot = snapshot
        self.readme = readme
        self.githubURL = githubURL
    }
}

public struct Repository: Equatable {
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }

    public static func discover(in root: URL) throws -> [Repository] {
        let children = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return children.compactMap { child in
            let name = child.lastPathComponent.precomposedStringWithCanonicalMapping
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  Git.succeeds(["-C", child.path, "rev-parse", "--git-dir"]),
                  (try? Validator.project(name)) != nil else { return nil }
            return Repository(name: name, url: child)
        }.sorted { $0.name < $1.name }
    }

    public static func ensure(name: String, in root: URL, bare: Bool = false) throws -> Repository {
        let name = name.precomposedStringWithCanonicalMapping
        try Validator.project(name)
        let url = root.appendingPathComponent(name + (bare ? ".git" : ""), isDirectory: true)
        if !Git.succeeds(["-C", url.path, "rev-parse", "--git-dir"]) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try Git.run(["init", "--quiet"] + (bare ? ["--bare"] : []) + [url.path])
            if !bare { _ = try Git.run(["-C", url.path, "config", "--local", "git-sync.mirrored", "true"]) }
        }
        return Repository(name: name, url: url)
    }

    public var commonDirectory: URL? {
        guard let path = try? Git.text(["-C", url.path, "rev-parse", "--git-common-dir"]) else { return nil }
        return URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
    }

    public func shortStatus() throws -> String {
        if try Git.text(["-C", url.path, "rev-parse", "--is-bare-repository"]) == "true"
            || (try? Git.text(["-C", url.path, "config", "--bool", "git-sync.mirrored"])) == "true" {
            return "Mirrored"
        }
        let branch = try (try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "--short", "HEAD"]))
            ?? "Detached \(try Git.text(["-C", url.path, "rev-parse", "--short", "HEAD"]))"
        let changes = try Git.text(["--no-optional-locks", "-C", url.path, "status",
                                    "--porcelain=v1", "--untracked-files=all"])
            .split(separator: "\n").count
        return "\(branch) · \(changes == 0 ? "clean" : "\(changes) changed")"
    }

    public var placement: ProjectPlacement {
        if (try? Git.text(["-C", url.path, "rev-parse", "--is-bare-repository"])) == "true" { return .mirrored }
        let markedMirror = (try? Git.text(["-C", url.path, "config", "--bool", "git-sync.mirrored"])) == "true"
        return !markedMirror && Git.succeeds(["-C", url.path, "rev-parse", "--verify", "HEAD"])
            ? .checkedOut : .mirrored
    }

    public var defaultBranch: String? {
        if let remoteHead = try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]),
           !remoteHead.isEmpty { return remoteHead.split(separator: "/").last.map(String.init) }
        for branch in ["main", "master"] where Git.succeeds(["-C", url.path, "rev-parse", "--verify", "refs/heads/\(branch)"]) {
            return branch
        }
        for branch in ["main", "master"] {
            let refs = (try? Git.text([
                "-C", url.path, "for-each-ref", "--format=%(refname)", "refs/remotes"
            ]).split(whereSeparator: \.isNewline).map(String.init)) ?? []
            if refs.contains(where: { $0.hasSuffix("/\(branch)") }) { return branch }
        }
        return nil
    }

    public var githubURL: URL? {
        guard let origin = try? Git.text(["-C", url.path, "remote", "get-url", "origin"]) else { return nil }
        return Self.githubURL(forOrigin: origin)
    }

    static func githubURL(forOrigin origin: String) -> URL? {
        let origin = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String
        if let components = URLComponents(string: origin), let host = components.host {
            guard host.lowercased() == "github.com" || host.lowercased() == "www.github.com" else { return nil }
            path = components.path
        } else {
            let parts = origin.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].split(separator: "@").last?.lowercased() == "github.com" else { return nil }
            path = String(parts[1])
        }

        var components = path.split(separator: "/").map(String.init)
        guard components.count == 2 else { return nil }
        if components[1].lowercased().hasSuffix(".git") { components[1].removeLast(4) }
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }

        var url = URLComponents()
        url.scheme = "https"
        url.host = "github.com"
        url.path = "/\(components[0])/\(components[1])"
        return url.url
    }

    public static func setPlacement(name: String, in root: URL, to requested: ProjectPlacement,
                                    branch: String? = nil) throws -> Repository {
        try Validator.project(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.invalidConfiguration("Projects folder does not exist: \(root.path)")
        }
        let repositoryURL = root.appendingPathComponent(name, isDirectory: true)
        let exists = Git.succeeds(["-C", repositoryURL.path, "rev-parse", "--git-dir"])

        switch requested {
        case .mirrored:
            let repository = exists ? Repository(name: name, url: repositoryURL) : try ensure(name: name, in: root)
            if repository.placement == .checkedOut { try repository.removeCheckout() }
            return Repository(name: name, url: repositoryURL)
        case .checkedOut:
            let repository = exists ? Repository(name: name, url: repositoryURL) : try ensure(name: name, in: root)
            if repository.placement != .checkedOut { try repository.createCheckout(branch: branch) }
            return repository
        case .notPresent:
            guard exists else { return Repository(name: name, url: repositoryURL) }
            let repository = Repository(name: name, url: repositoryURL)
            if repository.placement == .checkedOut, repository.cleanCheckoutRef() == nil {
                throw SyncError.invalidConfiguration("The checkout must be on a branch and completely clean.")
            }
            try repository.moveToTrash()
            return repository
        case .unknown:
            throw SyncError.invalidConfiguration("Unknown is not a project placement.")
        }
    }

    private func createCheckout(branch requestedBranch: String?) throws {
        let branch = requestedBranch ?? defaultBranch
        guard let branch, Git.checkRef("refs/heads/\(branch)") else {
            throw SyncError.invalidConfiguration("Choose a branch to check out.")
        }
        if Git.succeeds(["-C", url.path, "rev-parse", "--verify", "refs/heads/\(branch)"]) {
            _ = try Git.run(["-C", url.path, "checkout", "--quiet", branch])
        } else {
            let refs = try Git.text([
                "-C", url.path, "for-each-ref", "--format=%(refname)", "refs/remotes"
            ]).split(whereSeparator: \.isNewline).map(String.init).sorted()
            guard let source = refs.first(where: { $0.hasSuffix("/\(branch)") }) else {
                throw SyncError.invalidConfiguration("Branch \(branch) is not available yet.")
            }
            _ = try Git.run(["-C", url.path, "checkout", "--quiet", "-b", branch, source])
        }
        _ = try Git.run(["-C", url.path, "config", "--local", "--unset-all", "git-sync.mirrored"], allowFailure: true)
    }

    private func removeCheckout() throws {
        guard cleanCheckoutRef() != nil else {
            throw SyncError.invalidConfiguration("The checkout must be on a branch and completely clean.")
        }
        #if os(macOS)
        let manager = FileManager.default
        var trashed: NSURL?
        try manager.trashItem(at: url, resultingItemURL: &trashed)
        guard let trashed = trashed as URL? else {
            throw SyncError.invalidConfiguration("The checkout could not be moved to Trash.")
        }
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        try manager.moveItem(at: trashed.appendingPathComponent(".git"), to: url.appendingPathComponent(".git"))
        _ = try Git.run(["-C", url.path, "config", "--local", "git-sync.mirrored", "true"])
        #else
        throw SyncError.invalidConfiguration("Removing repositories requires a host with recoverable Trash.")
        #endif
    }

    private func moveToTrash() throws {
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        throw SyncError.invalidConfiguration("Removing repositories requires a host with recoverable Trash.")
        #endif
    }

    public func snapshot(limit: Int = 250) throws -> RepositorySnapshot {
        let references = try referenceSnapshot()
        let head = try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "--short", "HEAD"])
        return try snapshot(limit: limit, references: references, revisions: ["--all"], head: head)
    }

    public func content(limit: Int = 250) throws -> RepositoryContent {
        RepositoryContent(snapshot: try snapshot(limit: limit), readme: readme(), githubURL: githubURL)
    }

    func snapshot(limit: Int, references: [RepositoryReference], revisions: [String],
                  head: String?) throws -> RepositorySnapshot {
        guard !revisions.isEmpty else {
            let branches = references.filter { $0.fullName.hasPrefix("refs/heads/") }.map(\.name).sorted()
            return RepositorySnapshot(commits: [], references: references, head: head, branches: branches)
        }
        let data = try Git.run([
            "-C", url.path, "log", "--topo-order", "--date-order", "-n", String(max(1, limit)),
            "--format=%H%x00%P%x00%an%x00%aI%x00%B%x00%x1e",
        ] + revisions)
        let formatter = ISO8601DateFormatter()
        let commits = data.split(separator: 0x1e).compactMap { record -> RepositoryCommit? in
            let fields = record.split(separator: 0, maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count >= 5 else { return nil }
            let oid = String(decoding: fields[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !oid.isEmpty else { return nil }
            let parents = String(decoding: fields[1], as: UTF8.self).split(separator: " ").map(String.init)
            let author = String(decoding: fields[2], as: UTF8.self)
            let date = formatter.date(from: String(decoding: fields[3], as: UTF8.self)) ?? .distantPast
            let message = String(decoding: fields[4], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return RepositoryCommit(oid: oid, parents: parents, author: author, date: date, message: message)
        }
        let branches = references.filter { $0.fullName.hasPrefix("refs/heads/") }.map(\.name).sorted()
        return RepositorySnapshot(commits: commits, references: references, head: head, branches: branches)
    }

    public func diff(at oid: String) throws -> String {
        try Validator.oid(oid)
        return try Git.text([
            "-C", url.path, "show", "--format=", "--no-color", "--no-ext-diff",
            "--diff-merges=first-parent", "--find-renames", oid, "--",
        ])
    }

    public func readme(at requestedRef: String? = nil) -> RepositoryReadme? {
        let checkedOut = requestedRef == nil && placement == .checkedOut
        let ref = requestedRef ?? (checkedOut ? "HEAD" : defaultReadmeRef())
        guard let ref else { return nil }
        for name in ["README.md", "README", "README.markdown", "README.txt"] {
            if let data = try? Git.run(["-C", url.path, "show", "\(ref):\(name)"]) {
                let markdown = String(decoding: data, as: UTF8.self)
                return RepositoryReadme(markdown: markdown, source: checkedOut ? "Checked out HEAD" : ref)
            }
        }
        return nil
    }

    func referenceSnapshot() throws -> [RepositoryReference] {
        let data = try Git.run([
            "-C", url.path, "for-each-ref", "--format=%(refname)%00%(objectname)%00%(*objectname)",
            "refs/heads", "refs/remotes", "refs/tags", "refs/sync",
        ])
        return data.split(separator: 10).compactMap { line in
            let fields = line.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            return RepositoryReference(
                fullName: String(decoding: fields[0], as: UTF8.self),
                oid: fields.count == 3 && !fields[2].isEmpty
                    ? String(decoding: fields[2], as: UTF8.self)
                    : String(decoding: fields[1], as: UTF8.self)
            )
        }
    }

    private func defaultReadmeRef() -> String? {
        if let remoteHead = try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]),
           !remoteHead.isEmpty { return remoteHead }
        for ref in ["refs/heads/main", "refs/heads/master"]
            where Git.succeeds(["-C", url.path, "rev-parse", "--verify", ref]) { return ref }
        let refs = (try? Git.text([
            "-C", url.path, "for-each-ref", "--format=%(refname)", "refs/remotes"
        ]).split(whereSeparator: \.isNewline).map(String.init)) ?? []
        return refs.first(where: { $0.hasSuffix("/main") }) ?? refs.first(where: { $0.hasSuffix("/master") })
    }

    public func sourceRefs() throws -> [String: String] {
        let data = try Git.run([
            "-C", url.path, "for-each-ref", "--format=%(refname)%00%(objectname)",
            "refs/heads", "refs/tags", "refs/stash",
        ])
        return parseRefs(data).filter { ref, _ in
            ref == "refs/stash" || ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/tags/")
        }
    }

    func cleanCheckoutRef() -> String? {
        guard let ref = try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "HEAD"]),
              ref.hasPrefix("refs/heads/"),
              (try? Git.text(["-C", url.path, "status", "--porcelain", "--untracked-files=normal"]))?.isEmpty == true else {
            return nil
        }
        return ref
    }

    public func knownOIDs() throws -> [String] {
        let data = try Git.run(["-C", url.path, "for-each-ref", "--format=%(objectname)"])
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    public func configureRemote(_ peer: PeerRepositoryLocation) throws {
        try peer.validate()
        let remote = peer.remoteName
        let key = "remote.\(remote)"
        _ = try Git.run(["-C", url.path, "config", "--local", "--replace-all",
                         "\(key).url", peer.url(for: name)])
        _ = try Git.run(["-C", url.path, "config", "--local", "--replace-all",
                         "\(key).fetch", "+refs/heads/*:refs/remotes/\(Validator.remote(peer.machine))/*"])
        _ = try Git.run(["-C", url.path, "config", "--local", "--add",
                         "\(key).fetch", "+refs/tags/*:refs/sync/\(peer.machine)/tags/*"])
        _ = try Git.run(["-C", url.path, "config", "--local", "\(key).tagOpt", "--no-tags"])
        _ = try Git.run(["-C", url.path, "config", "--local", "\(key).prune", "true"])
    }

    public func pack(oid: String, excluding candidates: [String]) throws -> Data {
        try Validator.oid(oid)
        let expressions = Set(candidates).map { "\($0)^{object}" }
        let existing: [String]
        if expressions.isEmpty {
            existing = []
        } else {
            let input = expressions.joined(separator: "\n") + "\n"
            let output = try Git.run(
                ["-C", url.path, "cat-file", "--batch-check=%(objectname)"],
                input: Data(input.utf8)
            )
            existing = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline)
                .compactMap {
                    let oid = String($0)
                    return (try? Validator.oid(oid)) == nil ? nil : oid
                }
        }
        let revisions = ([oid] + existing.map { "^\($0)" }).joined(separator: "\n") + "\n"
        return try Git.run(
            ["-C", url.path, "pack-objects", "--stdout", "--revs", "--thin"],
            input: Data(revisions.utf8)
        )
    }

    public func install(pack: Data, target oid: String) throws {
        try Validator.oid(oid)
        _ = try Git.run(["-C", url.path, "index-pack", "--stdin", "--fix-thin"], input: pack)
        guard Git.succeeds(["-C", url.path, "cat-file", "-e", "\(oid)^{object}"]) else {
            throw SyncError.invalidProtocol("Installed pack does not contain target object")
        }
    }

    private func parseRefs(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        for line in data.split(separator: 10) {
            let fields = line.split(separator: 0, maxSplits: 1)
            if fields.count == 2 { result[String(decoding: fields[0], as: UTF8.self)] = String(decoding: fields[1], as: UTF8.self) }
        }
        return result
    }
}
