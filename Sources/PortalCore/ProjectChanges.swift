import Foundation
import PortalWatch

/// Complete read-only state, so a slow consumer may safely retain only the newest message.
public struct ProjectChange: Codable, Sendable {
    public static let currentVersion = 3
    public let version: Int
    public let projects: [String: ObservedProject]
    public let failure: String?
    public init(version: Int = currentVersion, projects: [String: ObservedProject] = [:], failure: String? = nil) {
        self.version = version
        self.projects = projects
        self.failure = failure
    }
    public func checked() throws -> Self {
        guard version == Self.currentVersion else {
            throw SyncError.invalidProtocol("Unsupported project watch version: \(version)")
        }
        if let failure { throw SyncError.invalidConfiguration(failure) }
        for (name, project) in projects {
            try Validator.project(name)
            guard name == project.project.name else {
                throw SyncError.invalidProtocol("Project watch name mismatch")
            }
        }
        return self
    }
}

public struct ObservedProject: Codable, Equatable, Sendable {
    public let project: PeerProject
    public let snapshot: RepositorySnapshot
    public let status: String
    public let revision: UUID
}

/// Compare Git-visible state before doing expensive inventory/staging reads.
/// Index refreshes, object installation and ignored build outputs are not changes.
struct ProjectChangeScanner {
    private var fingerprints: [String: Data] = [:]
    private var projects: [String: ObservedProject] = [:]
    private var initialized = false

    mutating func scan(_ repositories: [Repository], affected: Set<String>? = nil) throws -> ProjectChange? {
        let names = Set(repositories.map(\.name))
        var changed = !initialized || Set(projects.keys) != names
        projects = projects.filter { names.contains($0.key) }
        fingerprints = fingerprints.filter { names.contains($0.key) }
        for repository in repositories {
            guard affected == nil || affected!.contains(repository.name) || projects[repository.name] == nil else { continue }
            let fingerprint = try repository.observationFingerprint()
            guard fingerprints[repository.name] != fingerprint else { continue }
            let snapshot = try repository.snapshot(limit: 0)
            let project = PeerProject(name: repository.name, placement: repository.placement,
                defaultBranch: repository.defaultBranch, githubRepositories: repository.githubRepositories,
                workingChanges: snapshot.workingChanges, branchTips: snapshot.branchTips)
            projects[repository.name] = ObservedProject(project: project, snapshot: snapshot,
                status: try repository.shortStatus(), revision: UUID())
            fingerprints[repository.name] = fingerprint
            changed = true
        }
        initialized = true
        return changed ? ProjectChange(projects: projects) : nil
    }
}

extension Repository {
    fileprivate func observationFingerprint() throws -> Data {
        func git(_ arguments: [String]) throws -> Data {
            try Git.run(["--no-optional-locks", "-C", url.path] + arguments)
        }
        var parts = [try git(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"]),
                     try git(["config", "--local", "--null", "--list"]),
                     try git(["worktree", "list", "--porcelain", "-z"])]
        parts.append((try? git(["symbolic-ref", "HEAD"])) ?? Data())
        parts.append((try? git(["rev-parse", "--verify", "HEAD"])) ?? Data())
        if try git(["rev-parse", "--is-bare-repository"]) != Data("true\n".utf8) {
            parts.append(try git(["ls-files", "--stage", "-z"]))
            let files = try git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
            parts.append(files)
            // File metadata catches same-count edits without hashing entire worktrees.
            // Git selects the paths, so ignored files never enter this fingerprint.
            for path in files.split(separator: 0) {
                let file = url.appendingPathComponent(String(decoding: path, as: UTF8.self))
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let values = [FileAttributeKey.size, .modificationDate, .creationDate,
                              .systemFileNumber, .posixPermissions, .type].map {
                    attributes?[$0].map { value in
                        if let date = value as? Date { return String(date.timeIntervalSince1970) }
                        return String(describing: value)
                    } ?? "missing"
                }
                parts.append(try JSONEncoder().encode(values))
            }
        }
        return try JSONEncoder().encode(parts)
    }
}

/// Owned by the blocking watch command. The OS keeps events queued during scans.
final class ProjectChangeWatcher {
    private let observer: OpaquePointer
    init(root: URL, depth: Int32 = -1) throws {
        guard let observer = portal_observer_create() else {
            throw SyncError.invalidConfiguration("Could not create filesystem observer")
        }
        self.observer = observer
        try add(root, depth: depth)
    }
    deinit { portal_observer_destroy(observer) }
    func add(_ url: URL, depth: Int32 = -1) throws {
        guard portal_observer_add_depth(observer, url.resolvingSymlinksInPath().path, depth) == 0 else {
            throw SyncError.invalidConfiguration("Could not watch \(url.path); check filesystem watch limits and permissions")
        }
    }
    func takePaths() -> Set<String> {
        var paths = Set<String>()
        portal_observer_paths(observer, { path, context in
            guard let path, let context else { return }
            context.assumingMemoryBound(to: Set<String>.self).pointee.insert(
                URL(fileURLWithPath: String(cString: path)).standardizedFileURL.path)
        }, &paths)
        return paths
    }
    func wait(milliseconds: Int32 = -1) throws -> Bool {
        let result = portal_observer_wait(observer, milliseconds)
        guard result >= 0 else { throw SyncError.invalidConfiguration("Filesystem observation failed; reconnect to rescan") }
        return result != 0
    }
}

extension Runner {
    /// SSH can leave a server process alive after a network loss. Requiring input
    /// renewals bounds that process's lifetime without polling repositories.
    public static func watchProjectClient(input: FileHandle = .standardInput) {
        DispatchQueue.global().async {
            while portal_wait_for_input(input.fileDescriptor, 90_000) == 1 {
                guard let byte = try? input.read(upToCount: 1), byte == Data([0]) else { exit(0) }
            }
            exit(0)
        }
    }
    public static func watchProjects(root: URL, version: Int, output: FileHandle = .standardOutput) throws {
        _ = try ProjectChange(version: version).checked()
        let watcher = try ProjectChangeWatcher(root: root)
        var scanner = ProjectChangeScanner()
        var repositories = try Repository.discover(in: root)
        var affected: Set<String>?
        var directories: [String: [String]] = [:]
        func updateWatches() throws {
            directories = [:]
            for repository in repositories {
                let common = repository.commonDirectory
                if let common { try watcher.add(common) }
                directories[repository.name] = [repository.url, common].compactMap { $0?.standardizedFileURL.path }
            }
        }
        try updateWatches()
        while true {
            if let change = try scanner.scan(repositories, affected: affected) {
                try BackupControlConnection.send(change, to: output)
            }
            _ = try watcher.wait()
            // Coalesce a burst, without scheduling any idle scans. Bound the drain
            // so a continuously changing checkout still publishes updates.
            for _ in 0..<4 {
                if try !watcher.wait(milliseconds: 125) { break }
            }
            let paths = watcher.takePaths()
            // Discovery only needs root/first-level or Git initialization events.
            let rootPath = root.standardizedFileURL.path
            let discovery = paths.contains { path in
                path == "/" || path == rootPath ||
                URL(fileURLWithPath: path).deletingLastPathComponent().path == rootPath ||
                path.hasSuffix("/.git") || path.hasSuffix("/HEAD")
            }
            if discovery {
                repositories = try Repository.discover(in: root)
                try updateWatches()
            }
            affected = []
            for repository in repositories {
                let watched = directories[repository.name] ?? []
                let matching = paths.filter { path in
                    path == "/" || path == rootPath || watched.contains {
                        path == $0 || path.hasPrefix($0 + "/")
                    }
                }
                guard !matching.isEmpty else { continue }
                let checkout = repository.url.standardizedFileURL.path
                let metadata = watched.dropFirst()
                let needsScan = matching.contains { path in
                    path == "/" || path == rootPath || path == checkout ||
                    metadata.contains { path == $0 || path.hasPrefix($0 + "/") } ||
                    !path.hasPrefix(checkout + "/")
                }
                if !needsScan {
                    let relative = matching.map { String($0.dropFirst(checkout.count + 1)) }
                    let input = Data((relative.joined(separator: "\0") + "\0").utf8)
                    let ignored = try Git.run(["--no-optional-locks", "-C", repository.url.path,
                        "check-ignore", "--stdin", "-z"], input: input, successStatuses: [0, 1])
                    if Set(ignored.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }) == Set(relative) {
                        continue
                    }
                }
                affected?.insert(repository.name)
            }
        }
    }

    public static func projectWatchProcess(_ configuration: Configuration) throws -> Process {
        try configuration.validate()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=2", "-T", "--", configuration.peer,
            remoteCommand(configuration.remoteExecutable, ["watch-projects", "--root", configuration.remoteRoot,
                "--watch-version", String(ProjectChange.currentVersion)])]
        return process
    }
}
