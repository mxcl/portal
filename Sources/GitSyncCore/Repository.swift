import Foundation

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

    public static func ensure(name: String, in root: URL) throws -> Repository {
        let name = name.precomposedStringWithCanonicalMapping
        try Validator.project(name)
        let url = root.appendingPathComponent(name, isDirectory: true)
        if !Git.succeeds(["-C", url.path, "rev-parse", "--git-dir"]) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try Git.run(["init", "--quiet", url.path])
        }
        return Repository(name: name, url: url)
    }

    public var commonDirectory: URL? {
        guard let path = try? Git.text(["-C", url.path, "rev-parse", "--git-common-dir"]) else { return nil }
        return URL(fileURLWithPath: path, relativeTo: url).standardizedFileURL
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

    public func knownOIDs() throws -> [String] {
        let data = try Git.run(["-C", url.path, "for-each-ref", "--format=%(objectname)"])
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    public func pack(oid: String, excluding candidates: [String]) throws -> Data {
        try Validator.oid(oid)
        let known = candidates.filter { Git.succeeds(["-C", url.path, "cat-file", "-e", "\($0)^{object}"]) }
        let revisions = ([oid] + known.map { "^\($0)" }).joined(separator: "\n") + "\n"
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
