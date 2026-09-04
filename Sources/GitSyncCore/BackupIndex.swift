import Foundation

public enum BackupStatus: String, Codable, Sendable {
    case mirrored
    case candidate
    case unknown
    case archived
}

public struct BackupSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let machine: String
    public let branches: [String]

    fileprivate let syncMachines: [String]
}

public struct BackupItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let status: BackupStatus
    public let mirroredBy: [String]
    public let snapshots: [BackupSnapshot]
}

public final class BackupIndex: @unchecked Sendable {
    private static let storedSnapshotID = ".stored"

    private struct Catalog: Codable {
        var machine: String
        var repositories: Set<String>
    }

    private struct Document: Codable {
        var catalogs: [String: Catalog] = [:]
        var archived: Set<String> = []
    }

    private struct RepositoryInfo {
        let name: String
        let url: URL
        let snapshots: [BackupSnapshot]
    }

    private let url: URL
    private let lock = NSLock()
    private var document: Document

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } else {
            document = Document()
        }
    }

    public func replaceCatalog(machine: String, repositories: [String]) throws {
        try Validator.machine(machine)
        let names = try Set(repositories.map {
            let name = $0.precomposedStringWithCanonicalMapping
            try Validator.project(name)
            return name
        })
        lock.lock(); defer { lock.unlock() }
        document.catalogs[Validator.remote(machine)] = Catalog(machine: machine, repositories: names)
        document.archived.subtract(names)
        try save()
    }

    public func items(in root: URL) throws -> [BackupItem] {
        let repositories = try Self.repositories(in: root)
        lock.lock(); let document = document; lock.unlock()
        return repositories.map { repository in
            let snapshots = repository.snapshots.map { snapshot in
                BackupSnapshot(id: snapshot.id,
                               machine: document.catalogs[snapshot.id]?.machine ?? snapshot.machine,
                               branches: snapshot.branches, syncMachines: snapshot.syncMachines)
            }
            let mirroredBy = document.catalogs.values
                .filter { $0.repositories.contains(repository.name) }
                .map(\.machine).sorted()
            let knownSources = Set(document.catalogs.keys)
            let snapshotSources = Set(snapshots.map(\.id)).subtracting([Self.storedSnapshotID])
            let status: BackupStatus
            if !mirroredBy.isEmpty {
                status = .mirrored
            } else if document.catalogs.isEmpty || !snapshotSources.isSubset(of: knownSources) {
                status = .unknown
            } else {
                status = .archived
            }
            return BackupItem(name: repository.name, status: status, mirroredBy: mirroredBy,
                              snapshots: snapshots)
        }
    }

    public func archive(_ name: String, in root: URL) throws {
        try Validator.project(name)
        guard try items(in: root).first(where: { $0.name == name })?.status == .archived else {
            throw SyncError.invalidConfiguration("Only backups confirmed absent from every known host are archived.")
        }
        lock.lock(); defer { lock.unlock() }
        guard !document.catalogs.values.contains(where: { $0.repositories.contains(name) }) else {
            throw SyncError.invalidConfiguration("\(name) is still mirrored by a host.")
        }
        document.archived.insert(name)
        try save()
    }

    public static func restore(_ name: String, snapshotID: String,
                               from backupRoot: URL, to projectsRoot: URL) throws {
        try Validator.project(name)
        guard let repository = try repositories(in: backupRoot).first(where: { $0.name == name }),
              let snapshot = repository.snapshots.first(where: { $0.id == snapshotID }) else {
            throw SyncError.invalidConfiguration("The selected backup snapshot is no longer available.")
        }
        try restoreSource(name, snapshot: snapshot, from: repository.url, to: projectsRoot)
    }

    public static func restore(_ name: String, snapshot: BackupSnapshot,
                               from bundle: URL, to projectsRoot: URL) throws {
        try Validator.project(name)
        try restoreSource(name, snapshot: snapshot, from: bundle, to: projectsRoot)
    }

    public static func exportBundle(_ name: String, snapshotID: String,
                                    from backupRoot: URL, to bundle: URL) throws {
        try Validator.project(name)
        guard let repository = try repositories(in: backupRoot).first(where: { $0.name == name }),
              repository.snapshots.contains(where: { $0.id == snapshotID }) else {
            throw SyncError.invalidConfiguration("The selected backup snapshot is no longer available.")
        }
        _ = try Git.run(["-C", repository.url.path, "bundle", "create", bundle.path, "--all"])
    }

    private static func restoreSource(_ name: String, snapshot: BackupSnapshot,
                                     from source: URL, to projectsRoot: URL) throws {
        let manager = FileManager.default
        let target = projectsRoot.appendingPathComponent(name, isDirectory: true)
        guard !manager.fileExists(atPath: target.path) else {
            throw SyncError.invalidConfiguration("A project named \(name) already exists on this Mac.")
        }
        let temporary = projectsRoot.appendingPathComponent(".git-sync-unarchive-\(UUID().uuidString)",
                                                            isDirectory: true)
        do {
            _ = try Git.run(["init", "--quiet", "--initial-branch",
                             "git-sync-restore-\(UUID().uuidString)", temporary.path])
            var refspecs = [
                "+refs/remotes/*:refs/remotes/*",
                "+refs/sync/*:refs/sync/*",
            ]
            if snapshot.id == storedSnapshotID {
                refspecs.append("+refs/heads/*:refs/heads/*")
                refspecs.append("+refs/tags/*:refs/tags/*")
                if Git.succeeds(["ls-remote", "--exit-code", source.path, "refs/stash"]) {
                    refspecs.append("+refs/stash:refs/stash")
                }
            } else {
                refspecs.append("+refs/remotes/\(snapshot.id)/*:refs/heads/*")
            }
            for machine in snapshot.syncMachines {
                refspecs.append("+refs/sync/\(machine)/tags/*:refs/tags/*")
                if Git.succeeds(["ls-remote", "--exit-code", source.path,
                                 "refs/sync/\(machine)/stash"]) {
                    refspecs.append("+refs/sync/\(machine)/stash:refs/stash")
                }
            }
            _ = try Git.run(["-C", temporary.path, "fetch", "--quiet", "--no-tags",
                             source.path] + refspecs)
            if let branch = preferredBranch(snapshot.branches) {
                _ = try Git.run(["-C", temporary.path, "symbolic-ref", "HEAD", "refs/heads/\(branch)"])
                _ = try Git.run(["-C", temporary.path, "reset", "--quiet", "--hard", branch])
            }
            try manager.moveItem(at: temporary, to: target)
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private static func repositories(in root: URL) throws -> [RepositoryInfo] {
        try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).compactMap { url in
            let filename = url.lastPathComponent.precomposedStringWithCanonicalMapping
            guard filename.hasSuffix(".git"), filename.count > 4,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  Git.succeeds(["-C", url.path, "rev-parse", "--is-bare-repository"]) else { return nil }
            let name = String(filename.dropLast(4))
            guard (try? Validator.project(name)) != nil else { return nil }
            return RepositoryInfo(name: name, url: url, snapshots: try snapshots(in: url))
        }.sorted { $0.name < $1.name }
    }

    private static func snapshots(in repository: URL) throws -> [BackupSnapshot] {
        struct SnapshotState {
            var branches = Set<String>()
            var syncMachines = Set<String>()
        }
        let output = try Git.text(["-C", repository.path, "for-each-ref", "--format=%(refname)"])
        var states: [String: SnapshotState] = [:]
        for ref in output.split(whereSeparator: \.isNewline).map(String.init) {
            if ref.hasPrefix("refs/remotes/") {
                let suffix = ref.dropFirst("refs/remotes/".count)
                let fields = suffix.split(separator: "/", maxSplits: 1)
                guard fields.count == 2 else { continue }
                states[String(fields[0]), default: SnapshotState()].branches.insert(String(fields[1]))
            } else if ref.hasPrefix("refs/heads/") {
                let branch = String(ref.dropFirst("refs/heads/".count))
                states[storedSnapshotID, default: SnapshotState()].branches.insert(branch)
            } else if ref.hasPrefix("refs/tags/") || ref == "refs/stash" {
                states[storedSnapshotID] = states[storedSnapshotID] ?? SnapshotState()
            } else if ref.hasPrefix("refs/sync/") {
                let suffix = ref.dropFirst("refs/sync/".count)
                guard let machineField = suffix.split(separator: "/", maxSplits: 1).first else { continue }
                let machine = String(machineField)
                states[Validator.remote(machine), default: SnapshotState()].syncMachines.insert(machine)
            }
        }
        return states.map { remote, state in
            let machine = remote == storedSnapshotID
                ? "Stored backup"
                : state.syncMachines.sorted().first ?? remote
            return BackupSnapshot(id: remote, machine: machine,
                                  branches: state.branches.sorted(),
                                  syncMachines: state.syncMachines.sorted())
        }.sorted { $0.machine.localizedStandardCompare($1.machine) == .orderedAscending }
    }

    private static func preferredBranch(_ branches: [String]) -> String? {
        if branches.contains("main") { return "main" }
        if branches.contains("master") { return "master" }
        return branches.first
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}
