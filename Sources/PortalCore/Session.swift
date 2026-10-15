import Foundation

public final class SyncSession {
    private let root: URL
    private let renameRecords: [ProjectRename.Record]
    private let machine: String
    private let includedRepositories: Set<String>?
    private let peerRepositoryLocation: PeerRepositoryLocation?
    private let connection: FramedConnection
    private let state: StateStore
    private let logger: (String) -> Void
    private let catalogObserver: ((String, [String]) throws -> Void)?
    private let repositoryObserver: ((String) -> Void)?
    private let backupProgress: ((BackupProgress) -> Void)?
    private let isInitiator: Bool
    private let receiveOnly: Bool
    private let syncCheckouts: Bool
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "portal.control")
    private var peerMachine: String?
    private var peerEpoch: String?
    private var peerKnown: [String: Set<String>] = [:]
    private var needsFullSync = Set<String>()
    private var repositories: [String: Repository] = [:]
    private var configuredRemotes = Set<String>()
    private var pendingBackupUpdates: [String: Int] = [:]
    private var stopped = false

    public init(root: URL, machine: String, input: FileHandle, output: FileHandle,
                stateURL: URL, repositories: Set<String>? = nil,
                peerRepositoryLocation: PeerRepositoryLocation? = nil, namingRevision: [UUID]? = nil,
                isInitiator: Bool = false,
                receiveOnly: Bool = false,
                backupProgress: ((BackupProgress) -> Void)? = nil,
                syncCheckouts: Bool = false,
                catalogObserver: ((String, [String]) throws -> Void)? = nil,
                repositoryObserver: ((String) -> Void)? = nil,
                logger: @escaping (String) -> Void = { _ in }) throws {
        try Validator.machine(machine)
        for repository in repositories ?? [] { try Validator.project(repository) }
        try peerRepositoryLocation?.validate()
        self.root = root
        self.machine = machine
        let access = try ProjectAccess(root: root)
        defer { withExtendedLifetime(access) {} }
        renameRecords = access.records
        let revision = try ProjectRename.revision(access.records)
        if let namingRevision, namingRevision != revision {
            throw SyncError.invalidConfiguration("Project names changed; reload the connection before syncing.")
        }
        includedRepositories = repositories
        self.peerRepositoryLocation = peerRepositoryLocation
        connection = FramedConnection(input: input, output: output)
        state = try StateStore(url: stateURL)
        try state.applyRenames(access.records)
        self.backupProgress = backupProgress
        self.isInitiator = isInitiator
        self.receiveOnly = receiveOnly
        self.syncCheckouts = syncCheckouts
        self.catalogObserver = catalogObserver
        self.repositoryObserver = repositoryObserver
        self.logger = logger
    }

    public func run() throws {
        // Install before discovery so writes during the initial scan stay queued.
        let watcher = receiveOnly ? nil : try Watcher(root: root, repositories: [])
        if !receiveOnly { try refreshCatalog() }
        try connection.send(.hello(machine, epoch: state.sourceEpoch, namingRevision: ProjectRename.revision(renameRecords)))
        try connection.send(.catalog(Array(repositories.keys).sorted()))

        let receiver = DispatchGroup()
        receiver.enter()
        DispatchQueue.global().async { [self] in
            defer { receiver.leave(); setStopped() }
            do { try receiveLoop() } catch { logger("session ended: \(error)") }
        }

        if receiveOnly {
            receiver.wait()
            throw SyncError.disconnected
        }

        lock.lock(); let initial = Array(repositories.values); lock.unlock()
        guard let watcher else { throw SyncError.disconnected }
        try watcher.add(initial)
        while !isStopped {
            let fileSystemChanged = try watcher.wait()
            guard !isStopped else { break }
            lock.lock(); let reconciliationPending = !needsFullSync.isEmpty; lock.unlock()
            guard fileSystemChanged || reconciliationPending else { continue }
            let catalogScanNeeded = fileSystemChanged
            do {
                var changed: [String: Set<String>] = [:]
                if catalogScanNeeded {
                    lock.lock(); let oldNames = Set(repositories.keys); lock.unlock()
                    try refreshCatalog()
                    lock.lock(); let names = Set(repositories.keys); lock.unlock()
                    if names != oldNames { try connection.send(.catalog(Array(names).sorted())) }
                }
                lock.lock(); let current = repositories.values.sorted { $0.name < $1.name }; lock.unlock()
                if catalogScanNeeded {
                    try watcher.add(current)
                    for repository in current {
                        changed[repository.name] = try sendUpdates(
                            for: repository, full: false
                        )
                    }
                }
                for repository in current {
                    lock.lock(); let full = needsFullSync.remove(repository.name) != nil; lock.unlock()
                    if full {
                        _ = try sendUpdates(for: repository, full: true, excluding: changed[repository.name] ?? [])
                    }
                }
            } catch {
                logger("scan failed: \(error)")
                throw error // Reconnect and reconcile after a failed event scan.
            }
        }
        receiver.wait()
        throw SyncError.disconnected
    }

    private func receiveLoop() throws {
        while true {
            let message = try connection.receiveMessage()
            let names = message.repositories ?? message.update.map { [$0.repository] } ?? message.repository.map { [$0] } ?? []
            let access = try ProjectAccess(root: root, names: names, expected: renameRecords)
            defer { withExtendedLifetime(access) {} }
            switch message.type {
            case "hello":
                let (peer, epoch) = try message.validatedHello(expectedRevision: ProjectRename.revision(renameRecords))
                if let peerRepositoryLocation, peer != peerRepositoryLocation.machine {
                    throw SyncError.invalidProtocol(
                        "Connected host is \(peer), expected \(peerRepositoryLocation.machine)"
                    )
                }
                lock.lock()
                guard peerMachine == nil else { lock.unlock(); throw SyncError.invalidProtocol("Duplicate HELLO") }
                peerMachine = peer; peerEpoch = epoch
                lock.unlock()
                try configureRemotes()
                logger("connected to \(peer)")
            case "catalog":
                let (peer, _) = try currentPeer()
                let names = message.repositories ?? []
                for name in names {
                    try requireIncluded(name)
                }
                try catalogObserver?(peer, names)
                for name in names {
                    lock.lock(); let isNew = repositories[name] == nil; lock.unlock()
                    let repository = try Repository.ensure(name: name, in: root, bare: receiveOnly)
                    repositoryObserver?(name)
                    try configureRemote(for: repository)
                    lock.lock(); repositories[name] = repository; lock.unlock()
                    sendControl(.inventory(name, known: try repository.knownOIDs()))
                    if isNew && !receiveOnly { sendControl(.catalog([name])) }
                }
            case "inventory":
                _ = try currentPeer()
                guard let name = message.repository, let known = message.known else {
                    throw SyncError.invalidProtocol("INVENTORY is incomplete")
                }
                try Validator.project(name)
                try requireIncluded(name)
                for oid in known { try Validator.oid(oid) }
                lock.lock(); peerKnown[name] = Set(known); needsFullSync.insert(name); lock.unlock()
            case "update":
                guard let update = message.update else { throw SyncError.invalidProtocol("UPDATE is incomplete") }
                let pack = update.oid == nil ? nil : try connection.receivePack()
                try receive(update, pack: pack)
            case "ack":
                _ = try currentPeer()
                if let name = message.repository {
                    try Validator.project(name)
                    if let oid = message.oid { try Validator.oid(oid) }
                    lock.lock()
                    if let pending = pendingBackupUpdates[name], pending > 0 {
                        pendingBackupUpdates[name] = pending - 1
                        if pending == 1 { backupProgress?(BackupProgress(project: name, phase: .current)) }
                    }
                    lock.unlock()
                }
                if let name = message.repository, let oid = message.oid {
                    try Validator.project(name); try Validator.oid(oid)
                    lock.lock(); peerKnown[name, default: []].insert(oid); lock.unlock()
                    logger("replication progress: acknowledged \(name)")
                }
            case "error": logger("peer error: \(message.message ?? "unknown")")
            default: throw SyncError.invalidProtocol("Unknown message type: \(message.type)")
            }
        }
    }

    private func receive(_ update: RefUpdate, pack: Data?) throws {
        try Validator.project(update.repository)
        try requireIncluded(update.repository)
        try Validator.sourceRef(update.sourceRef)
        let (peer, epoch) = try currentPeer()
        let accepted = state.acceptedGeneration(
            peer: peer, epoch: epoch, repository: update.repository, ref: update.sourceRef
        )
        if update.generation < accepted || update.generation == 0 {
            sendControl(.ack(update)); return
        }
        let repository = try Repository.ensure(name: update.repository, in: root, bare: receiveOnly)
        try configureRemote(for: repository)
        if update.generation == accepted {
            let writer = try PeerRefWriter(repository: repository, peer: peer)
            if let oid = update.oid, try writer.currentOID(for: update.sourceRef) == nil {
                guard let pack else { throw SyncError.invalidProtocol("Object update has no pack") }
                try repository.install(pack: pack, target: oid)
                try writer.restoreMissing(sourceRef: update.sourceRef, oid: oid)
                repositoryObserver?(update.repository)
                logger("restored missing peer ref \(update.repository)/\(update.sourceRef)")
                sendControl(.ack(update)); return
            }
            if syncCheckouts, update.cleanCheckout == true, let oid = update.oid {
                guard try writer.currentOID(for: update.sourceRef) == oid else {
                    throw SyncError.invalidProtocol("Generation was reused with a different object")
                }
                let checkoutSynced = try writer.apply(
                    sourceRef: update.sourceRef, oid: oid, syncCheckout: true
                )
                if checkoutSynced { logger("fast-forwarded checkout \(update.repository)/\(update.sourceRef)") }
            }
            sendControl(.ack(update)); return
        }
        if let oid = update.oid {
            guard let pack else { throw SyncError.invalidProtocol("Object update has no pack") }
            try repository.install(pack: pack, target: oid)
        }
        let writer = try PeerRefWriter(repository: repository, peer: peer)
        let checkoutSynced = try writer.apply(
            sourceRef: update.sourceRef, oid: update.oid,
            syncCheckout: syncCheckouts && update.cleanCheckout == true
        )
        repositoryObserver?(update.repository)
        try writer.pruneExpired()
        try state.accept(generation: update.generation, peer: peer, epoch: epoch,
                         repository: update.repository, ref: update.sourceRef)
        sendControl(.ack(update))
        logger(Self.transferLog(sourceRef: update.sourceRef, machine: machine,
                                peer: peer, isInitiator: isInitiator))
        if checkoutSynced { logger("fast-forwarded checkout \(update.repository)/\(update.sourceRef)") }
    }

    private func sendControl(_ message: WireMessage) {
        controlQueue.async { [self] in
            do { try connection.send(message) }
            catch { logger("session ended: \(error)"); setStopped() }
        }
    }

    @discardableResult
    private func sendUpdates(for repository: Repository, full: Bool,
                             excluding excluded: Set<String> = []) throws -> Set<String> {
        let access = try ProjectAccess(root: root, names: [repository.name], expected: renameRecords)
        defer { withExtendedLifetime(access) {} }
        lock.lock(); let initialKnown = peerKnown[repository.name]; lock.unlock()
        guard var known = initialKnown else { return [] }
        let stored = try state.updates(machine: machine, repository: repository.name,
                                        refs: repository.sourceRefs(), full: full)
            .filter { !excluded.contains($0.sourceRef) }
        if let backupProgress {
            lock.lock()
            pendingBackupUpdates[repository.name, default: 0] += stored.count
            backupProgress(BackupProgress(project: repository.name,
                phase: pendingBackupUpdates[repository.name] == 0 ? .current : .transferring))
            lock.unlock()
        }
        guard !stored.isEmpty else { return [] }
        let cleanCheckout = syncCheckouts ? repository.cleanCheckoutRef() : nil
        let updates = stored.map {
                RefUpdate(repository: $0.repository, sourceRef: $0.sourceRef,
                          generation: $0.generation, oid: $0.oid,
                          cleanCheckout: $0.sourceRef == cleanCheckout ? true : nil)
            }
        for update in updates {
            let pack = try update.oid.map { try repository.pack(oid: $0, excluding: Array(known)) }
            try connection.send(update: update, pack: pack)
            if let oid = update.oid { known.insert(oid) }
        }
        return Set(updates.map(\.sourceRef))
    }

    private func refreshCatalog() throws {
        let access = try ProjectAccess(root: root, expected: renameRecords)
        defer { withExtendedLifetime(access) {} }
        let found = try Repository.discover(in: root, including: includedRepositories)
        for repository in found { try configureRemote(for: repository) }
        lock.lock(); repositories = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) }); lock.unlock()
    }

    private func configureRemotes() throws {
        lock.lock(); let current = Array(repositories.values); lock.unlock()
        for repository in current { try configureRemote(for: repository) }
    }

    private func configureRemote(for repository: Repository) throws {
        guard let peerRepositoryLocation else { return }
        lock.lock()
        let shouldConfigure = peerMachine != nil && configuredRemotes.insert(repository.name).inserted
        lock.unlock()
        guard shouldConfigure else { return }
        do {
            try repository.configureRemote(peerRepositoryLocation)
        } catch {
            lock.lock(); configuredRemotes.remove(repository.name); lock.unlock()
            throw error
        }
    }

    private func requireIncluded(_ name: String) throws {
        try Validator.project(name)
        guard includedRepositories?.contains(name) ?? true else {
            throw SyncError.invalidProtocol("Repository is not enabled: \(name)")
        }
    }

    private func currentPeer() throws -> (machine: String, epoch: String) {
        lock.lock(); defer { lock.unlock() }
        guard let peerMachine, let peerEpoch else {
            throw SyncError.invalidProtocol("Message arrived before HELLO")
        }
        return (peerMachine, peerEpoch)
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func setStopped() { lock.lock(); stopped = true; lock.unlock() }

    static func transferLog(sourceRef: String, machine: String, peer: String,
                            isInitiator: Bool) -> String {
        isInitiator ? "\(machine) ← \(peer)/\(sourceRef)" : "\(sourceRef) → \(machine)"
    }
}
