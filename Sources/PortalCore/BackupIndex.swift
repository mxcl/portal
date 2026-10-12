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
    // ponytail: serialize inventory I/O; split per repository if scan contention matters.
    private let inventoryLock = NSLock()
    private var inventoryRoot: URL?
    private var inventory: [String: RepositoryInfo] = [:]
    private var dirtyRepositories: Set<String> = []
    private var scannedAt: Date?

    public func invalidate(_ name: String, in root: URL) {
        inventoryLock.lock(); defer { inventoryLock.unlock() }
        if inventoryRoot == root { dirtyRepositories.insert(name) }
    }

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

    public func items(in root: URL, refresh: Bool = false, now: Date = Date()) throws -> [BackupItem] {
        inventoryLock.lock(); defer { inventoryLock.unlock() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.invalidConfiguration("Backup destination is unavailable: \(root.path)")
        }
        if refresh || inventoryRoot != root || now.timeIntervalSince(scannedAt ?? .distantPast) >= 3600 {
            let repositories = try Self.repositories(in: root)
            inventory = Dictionary(uniqueKeysWithValues: repositories.map { ($0.name, $0) })
            inventoryRoot = root
            scannedAt = now
            dirtyRepositories.removeAll()
        } else {
            for name in dirtyRepositories.sorted() {
                try Validator.project(name)
                inventory[name] = try Self.repository(at: root.appendingPathComponent(name + ".git"))
                dirtyRepositories.remove(name)
            }
        }
        let repositories = inventory.values.sorted { $0.name < $1.name }
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

    /// Explicit user deletion; never called by background retention or replication.
    public func delete(_ name: String, in root: URL) throws {
        try Validator.project(name)
        inventoryLock.lock(); defer { inventoryLock.unlock() }
        lock.lock(); defer { lock.unlock() }
        let target = root.appendingPathComponent(name + ".git")
        guard let repository = try Self.repository(at: target),
              try Git.text(["-C", target.path, "rev-parse", "--is-bare-repository"]) == "true",
              !(try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? false),
              !document.catalogs.isEmpty,
              !document.catalogs.values.contains(where: { $0.repositories.contains(name) }),
              Set(repository.snapshots.map(\.id)).subtracting([Self.storedSnapshotID])
                .isSubset(of: Set(document.catalogs.keys)) else {
            throw SyncError.invalidConfiguration("Only backups confirmed absent from every known host can be deleted.")
        }
        try FileManager.default.removeItem(at: target)
        inventory.removeValue(forKey: name)
        dirtyRepositories.remove(name)
        document.archived.remove(name)
        try save()
    }

    public static func restore(_ name: String, snapshotID: String,
                               from backupRoot: URL, to projectsRoot: URL) throws {
        try Validator.project(name)
        guard let repository = try repository(at: backupRoot.appendingPathComponent(name + ".git")),
              let snapshot = repository.snapshots.first(where: { $0.id == snapshotID }) else {
            throw SyncError.invalidConfiguration("The selected backup snapshot is no longer available.")
        }
        try restoreSource(name, snapshot: snapshot, from: repository.url, to: projectsRoot)
    }

    public static func restore(_ name: String, snapshot: BackupSnapshot,
                               from bundle: URL, to projectsRoot: URL) throws {
        try Validator.project(name)
        if snapshot.id != storedSnapshotID {
            try Validator.machine(snapshot.id)
            guard Git.checkRef("refs/remotes/\(snapshot.id)/branch") else {
                throw SyncError.invalidProtocol("Invalid backup snapshot source")
            }
        }
        for machine in snapshot.syncMachines {
            try Validator.machine(machine)
            guard Git.checkRef("refs/sync/\(machine)/tags/tag") else {
                throw SyncError.invalidProtocol("Invalid backup snapshot machine")
            }
        }
        for branch in snapshot.branches { try Validator.sourceRef("refs/heads/" + branch) }
        try restoreSource(name, snapshot: snapshot, from: bundle, to: projectsRoot)
    }

    public static func exportBundle(_ name: String, snapshotID: String,
                                    from backupRoot: URL, to bundle: URL) throws {
        try Validator.project(name)
        guard let repository = try repository(at: backupRoot.appendingPathComponent(name + ".git")),
              repository.snapshots.contains(where: { $0.id == snapshotID }) else {
            throw SyncError.invalidConfiguration("The selected backup snapshot is no longer available.")
        }
        _ = try Git.run(["-C", repository.url.path, "bundle", "create", bundle.path, "--all"])
    }

    public static func content(_ name: String, snapshotID: String,
                               from backupRoot: URL, limit: Int = 250) throws -> RepositoryContent {
        let (repository, snapshot) = try snapshotRepository(name, snapshotID: snapshotID, in: backupRoot)
        let (projected, revisions) = try searchReferences(repository, snapshot: snapshot)
        let branch = preferredBranch(snapshot.branches)
        let readmeRef = branch.map {
            snapshot.id == storedSnapshotID ? "refs/heads/\($0)" : "refs/remotes/\(snapshot.id)/\($0)"
        }
        return RepositoryContent(
            snapshot: try repository.snapshot(limit: limit,
                                              references: projected.values.sorted { $0.fullName < $1.fullName },
                                              revisions: revisions.sorted(), head: branch),
            readme: readmeRef.flatMap(repository.readme(at:)),
            githubURL: nil
        )
    }

    private static func searchReferences(_ repository: Repository, snapshot: BackupSnapshot) throws
        -> ([String: RepositoryReference], Set<String>) {
        let references = try repository.referenceSnapshot()
        var projected: [String: RepositoryReference] = [:]
        var revisions = Set<String>()

        func include(_ reference: RepositoryReference, as fullName: String? = nil) {
            let fullName = fullName ?? reference.fullName
            projected[fullName] = projected[fullName]
                ?? RepositoryReference(fullName: fullName, oid: reference.oid)
            revisions.insert(reference.fullName)
        }

        for reference in references {
            let ref = reference.fullName
            if ref.hasPrefix("refs/remotes/") {
                include(reference)
                let prefix = "refs/remotes/\(snapshot.id)/"
                if snapshot.id != storedSnapshotID, ref.hasPrefix(prefix) {
                    include(reference, as: "refs/heads/\(ref.dropFirst(prefix.count))")
                }
            } else if ref.hasPrefix("refs/sync/") {
                if ref.contains("/tags/") { include(reference) }
                for machine in snapshot.syncMachines {
                    let prefix = "refs/sync/\(machine)/tags/"
                    if ref.hasPrefix(prefix) {
                        include(reference, as: "refs/tags/\(ref.dropFirst(prefix.count))")
                    }
                }
            } else if snapshot.id == storedSnapshotID,
                      ref.hasPrefix("refs/heads/") || ref.hasPrefix("refs/tags/") {
                include(reference)
            }
        }

        if snapshot.id == storedSnapshotID {
            if Git.succeeds(["-C", repository.url.path, "rev-parse", "--verify", "refs/stash"]) {
                revisions.insert("refs/stash")
            }
        } else {
            for machine in snapshot.syncMachines {
                let stash = "refs/sync/\(machine)/stash"
                if Git.succeeds(["-C", repository.url.path, "rev-parse", "--verify", stash]) {
                    revisions.insert(stash)
                }
            }
        }

        return (projected, revisions)
    }

    public static func search(_ name: String, snapshotID: String, query: String,
                              from root: URL) throws -> RepositorySearchReply {
        let (repository, snapshot) = try snapshotRepository(name, snapshotID: snapshotID, in: root)
        let (references, _) = try searchReferences(repository, snapshot: snapshot)
        return try repository.search(query, references: Array(references.values))
    }

    public static func diff(_ name: String, snapshotID: String, oid: String,
                            from backupRoot: URL) throws -> String {
        let (repository, _) = try snapshotRepository(name, snapshotID: snapshotID, in: backupRoot)
        return try repository.diff(at: oid)
    }

    private static func snapshotRepository(_ name: String, snapshotID: String, in root: URL) throws
        -> (Repository, BackupSnapshot) {
        try Validator.project(name)
        guard let info = try repository(at: root.appendingPathComponent(name + ".git")),
              let snapshot = info.snapshots.first(where: { $0.id == snapshotID }) else {
            throw SyncError.invalidConfiguration("The selected backup snapshot is no longer available.")
        }
        return (Repository(name: name, url: info.url), snapshot)
    }

    private static func restoreSource(_ name: String, snapshot: BackupSnapshot,
                                     from source: URL, to projectsRoot: URL) throws {
        let manager = FileManager.default
        let target = projectsRoot.appendingPathComponent(name, isDirectory: true)
        guard !manager.fileExists(atPath: target.path) else {
            throw SyncError.invalidConfiguration("A project named \(name) already exists on the destination computer.")
        }
        let temporary = projectsRoot.appendingPathComponent(".portal-unarchive-\(UUID().uuidString)",
                                                            isDirectory: true)
        do {
            _ = try Git.run(["init", "--quiet", "--initial-branch",
                             "portal-restore-\(UUID().uuidString)", temporary.path])
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
        ).compactMap { try repository(at: $0) }.sorted { $0.name < $1.name }
    }

    private static func repository(at url: URL) throws -> RepositoryInfo? {
        let filename = url.lastPathComponent.precomposedStringWithCanonicalMapping
        guard filename.hasSuffix(".git"), filename.count > 4,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              Git.succeeds(["-C", url.path, "rev-parse", "--is-bare-repository"]) else { return nil }
        let name = String(filename.dropLast(4))
        guard (try? Validator.project(name)) != nil else { return nil }
        return RepositoryInfo(name: name, url: url, snapshots: try snapshots(in: url))
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
