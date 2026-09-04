import Foundation

public struct RepositoryReference: Equatable, Identifiable, Sendable {
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

public struct RepositoryCommit: Equatable, Identifiable, Sendable {
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

public struct RepositorySnapshot: Equatable, Sendable {
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

public struct RepositoryReadme: Equatable, Sendable {
    public let markdown: String
    public let source: String

    public init(markdown: String, source: String) {
        self.markdown = markdown
        self.source = source
    }
}

public struct Repository: Equatable {
    public let name: String
    public let url: URL

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
        }
        return Repository(name: name, url: url)
    }

    public var commonDirectory: URL? {
        guard let path = try? Git.text(["-C", url.path, "rev-parse", "--git-common-dir"]) else { return nil }
        return URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
    }

    public func snapshot(limit: Int = 250) throws -> RepositorySnapshot {
        let references = try referenceSnapshot()
        let data = try Git.run([
            "-C", url.path, "log", "--all", "--topo-order", "--date-order", "-n", String(max(1, limit)),
            "--format=%H%x00%P%x00%an%x00%aI%x00%B%x00%x1e",
        ])
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
        let head = try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "--short", "HEAD"])
        let branches = references.filter { $0.fullName.hasPrefix("refs/heads/") }.map(\.name).sorted()
        return RepositorySnapshot(commits: commits, references: references, head: head, branches: branches)
    }

    public func readme(at requestedRef: String? = nil) -> RepositoryReadme? {
        if requestedRef == nil,
           Git.succeeds(["-C", url.path, "rev-parse", "--is-inside-work-tree"]),
           Git.succeeds(["-C", url.path, "rev-parse", "--verify", "HEAD"]),
           let file = readmeFile(in: url),
           let markdown = try? String(contentsOf: file, encoding: .utf8) {
            return RepositoryReadme(markdown: markdown, source: "Checked out HEAD")
        }

        let ref = requestedRef ?? defaultReadmeRef()
        guard let ref else { return nil }
        for name in ["README.md", "README", "README.markdown", "README.txt"] {
            if let markdown = try? Git.text(["-C", url.path, "show", "\(ref):\(name)"]) {
                return RepositoryReadme(markdown: markdown, source: ref)
            }
        }
        return nil
    }

    private func referenceSnapshot() throws -> [RepositoryReference] {
        let data = try Git.run([
            "-C", url.path, "for-each-ref", "--format=%(refname)%00%(objectname)",
            "refs/heads", "refs/remotes", "refs/tags", "refs/sync",
        ])
        return data.split(separator: 10).compactMap { line in
            let fields = line.split(separator: 0, maxSplits: 1)
            guard fields.count == 2 else { return nil }
            return RepositoryReference(
                fullName: String(decoding: fields[0], as: UTF8.self),
                oid: String(decoding: fields[1], as: UTF8.self)
            )
        }
    }

    private func defaultReadmeRef() -> String? {
        if let remoteHead = try? Git.text(["-C", url.path, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]),
           !remoteHead.isEmpty { return remoteHead }
        for ref in ["refs/heads/main", "refs/heads/master"] where Git.succeeds(["-C", url.path, "rev-parse", "--verify", ref]) {
            return ref
        }
        return nil
    }

    private func readmeFile(in directory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.first { $0.lowercased() == "readme.md" }
            .map { directory.appendingPathComponent($0) }
            ?? names.first { $0.lowercased().hasPrefix("readme") }.map { directory.appendingPathComponent($0) }
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
                         "\(key).fetch", "+refs/heads/*:refs/remotes/\(remote)/*"])
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
