import Foundation

/// Persistent observation retains events while Git scans and transfers run.
public final class Watcher {
    private let observer: ProjectChangeWatcher
    private let rootPath: String
    private var metadata = Set<String>()

    public init(root: URL, repositories: [Repository]) throws {
        rootPath = root.standardizedFileURL.path
        observer = try ProjectChangeWatcher(root: root)
        try add(repositories)
    }

    public func add(_ repositories: [Repository]) throws {
        for repository in repositories {
            if let common = repository.commonDirectory {
                try observer.add(common)
                metadata.insert(common.standardizedFileURL.path)
            }
        }
    }

    public func wait(timeout: TimeInterval = 2) throws -> Bool {
        // Timeout only lets owners check cancellation/protocol messages; it never
        // requests a repository scan or reconciliation.
        guard try observer.wait(milliseconds: Int32(timeout * 1000)) else { return false }
        return observer.takePaths().contains { path in
            if path == "/" || path == rootPath || metadata.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return true
            }
            guard path.hasPrefix(rootPath + "/") else { return true }
            let relative = path.dropFirst(rootPath.count + 1).split(separator: "/")
            return relative.count <= 1 || relative.dropFirst().first == ".git" ||
                (relative.count == 2 && relative.last == "HEAD")
        }
    }
}
