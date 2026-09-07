import Foundation

public struct RepositoryFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
    public var isUntracked: Bool { status == "??" }
    public var isConflicted: Bool { status.contains("U") || status == "AA" || status == "DD" }
    public var isStaged: Bool { !isUntracked && status.first != " " }
    public var isUnstaged: Bool { isUntracked || status.last != " " }
}

extension Repository {
    /// Git supplies the paths: tracked files (including deletions) and non-ignored untracked files.
    public func files() throws -> [RepositoryFile] {
        let paths = try Git.run(["-C", url.path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
        let porcelain = try Git.run(["--no-optional-locks", "-C", url.path, "status", "--porcelain=v1", "-z",
                                     "--untracked-files=all"])
        var statuses: [String: String] = [:]
        var records = porcelain.split(separator: 0).makeIterator()
        while let record = records.next() {
            guard record.count >= 4 else { continue }
            let status = String(decoding: record.prefix(2), as: UTF8.self)
            statuses[String(decoding: record.dropFirst(3), as: UTF8.self)] = status
            if status.contains("R") || status.contains("C") { _ = records.next() }
        }
        let names = Set(paths.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
            .union(statuses.keys)
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { RepositoryFile(path: $0, status: statuses[$0] ?? "  ") }
    }

    public func fileDiff(path: String, staged: Bool) throws -> String {
        let args = ["--no-optional-locks", "--literal-pathspecs", "-C", url.path, "diff", "--no-ext-diff", "--no-textconv", "--no-color"]
            + (staged ? ["--cached"] : []) + ["--", path]
        return String(decoding: try Git.run(args), as: UTF8.self)
    }

    public func workingDiff(staged: Bool) throws -> String {
        let args = ["--no-optional-locks", "-C", url.path, "diff", "--no-ext-diff", "--no-textconv",
                    "--no-color", "--src-prefix=a/", "--dst-prefix=b/"]
        // Unmerged files use a unified diff against the merge base, which the renderer can display.
        var diff = try Git.run(args + (staged ? ["--cached"] : ["--base"]) + ["--"])
        if !staged {
            let paths = try Git.run(["-C", url.path, "ls-files", "--others", "--exclude-standard", "-z"])
            for path in paths.split(separator: 0) {
                // --no-index returns 1 for differences; stderr still indicates errors.
                diff.append(try Git.run(args + ["--no-index", "--", "/dev/null", String(decoding: path, as: UTF8.self)],
                                       successStatuses: [0, 1]))
            }
        }
        return String(decoding: diff, as: UTF8.self)
    }
}

/// A bounded, lossless UTF-8 document. Keep original bytes to detect outside edits before saving.
public struct RepositoryTextFile: Sendable {
    public let url: URL
    public let original: Data
    public let text: String

    public init(repository: URL, path: String) throws {
        let root = repository.resolvingSymlinksInPath().standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), !path.split(separator: "/").contains(".git"),
              url.resolvingSymlinksInPath().path == url.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 2 * 1024 * 1024 else {
            throw SyncError.invalidConfiguration("The editor supports regular UTF-8 text files up to 2 MB.")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 2 * 1024 * 1024, !bytes.contains(0), let text = String(data: bytes, encoding: .utf8) else {
            throw SyncError.invalidConfiguration("This file is not UTF-8 text. Open it in an external editor.")
        }
        self.url = url
        original = bytes
        self.text = text
    }

    public func save(_ text: String) throws -> RepositoryTextFile {
        guard url.resolvingSymlinksInPath().path == url.path,
              try Data(contentsOf: url) == original else {
            throw SyncError.invalidConfiguration("The file changed on disk. Copy your edits, then reload the file before saving.")
        }
        // Foundation strips a UTF-8 BOM when decoding; preserve it separately on disk.
        let bom = Data([0xef, 0xbb, 0xbf])
        let bytes = (original.starts(with: bom) ? bom : Data()) + Data(text.utf8)
        try bytes.write(to: url, options: .atomic)
        return RepositoryTextFile(url: url, original: bytes, text: text)
    }

    private init(url: URL, original: Data, text: String) {
        self.url = url
        self.original = original
        self.text = text
    }
}
