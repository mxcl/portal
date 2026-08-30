import Foundation

public final class SyncSession {
    private let root: URL
    private let machine: String
    private let includedRepositories: Set<String>?
    private let peerRepositoryLocation: PeerRepositoryLocation?
    private let connection: FramedConnection
    private let state: StateStore
    private let logger: (String) -> Void
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "git-sync.control")
    private var peerMachine: String?
    private var peerEpoch: String?
    private var peerKnown: [String: Set<String>] = [:]
    private var needsFullSync = Set<String>()
    private var repositories: [String: Repository] = [:]
    private var configuredRemotes = Set<String>()
    private var stopped = false

    public init(root: URL, machine: String, input: FileHandle, output: FileHandle,
                stateURL: URL, repositories: Set<String>? = nil,
                peerRepositoryLocation: PeerRepositoryLocation? = nil,
                logger: @escaping (String) -> Void = { _ in }) throws {
        try Validator.machine(machine)
        for repository in repositories ?? [] { try Validator.project(repository) }
        try peerRepositoryLocation?.validate()
        self.root = root
        self.machine = machine
        includedRepositories = repositories
        self.peerRepositoryLocation = peerRepositoryLocation
        connection = FramedConnection(input: input, output: output)
        state = try StateStore(url: stateURL)
        self.logger = logger
    }

    public func run() throws {
        try refreshCatalog()
        try connection.send(.hello(machine, epoch: state.sourceEpoch))
        try connection.send(.catalog(Array(repositories.keys).sorted()))

        let receiver = DispatchGroup()
        receiver.enter()
        DispatchQueue.global().async { [self] in
            defer { receiver.leave(); setStopped() }
            do { try receiveLoop() } catch { logger("session ended: \(error)") }
        }

        while !isStopped {
            lock.lock(); let watched = Array(repositories.values); lock.unlock()
            Watcher.wait(root: root, repositories: watched)
            guard !isStopped else { break }
            do {
                let oldNames = Set(repositories.keys)
                try refreshCatalog()
                if Set(repositories.keys) != oldNames {
                    try connection.send(.catalog(Array(repositories.keys).sorted()))
                }
                let current = repositories.values.sorted { $0.name < $1.name }
                var changed: [String: Set<String>] = [:]
                for repository in current {
                    changed[repository.name] = try sendUpdates(for: repository, full: false)
                }
                for repository in current {
                    lock.lock(); let full = needsFullSync.remove(repository.name) != nil; lock.unlock()
                    if full {
                        _ = try sendUpdates(for: repository, full: true, excluding: changed[repository.name] ?? [])
                    }
                }
            } catch {
                logger("scan failed: \(error)")
            }
        }
        receiver.wait()
        throw SyncError.disconnected
    }

    private func receiveLoop() throws {
        while true {
            let message = try connection.receiveMessage()
            switch message.type {
            case "hello":
                let (peer, epoch) = try message.validatedHello()
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
                _ = try currentPeer()
                for name in message.repositories ?? [] {
                    try requireIncluded(name)
                    lock.lock(); let isNew = repositories[name] == nil; lock.unlock()
                    let repository = try Repository.ensure(name: name, in: root)
                    try configureRemote(for: repository)
                    lock.lock(); repositories[name] = repository; lock.unlock()
                    sendControl(.inventory(name, known: try repository.knownOIDs()))
                    if isNew { sendControl(.catalog([name])) }
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
                if let name = message.repository, let oid = message.oid {
                    try Validator.project(name); try Validator.oid(oid)
                    lock.lock(); peerKnown[name, default: []].insert(oid); lock.unlock()
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
        if update.generation <= state.acceptedGeneration(
            peer: peer, epoch: epoch, repository: update.repository, ref: update.sourceRef
        ) {
            sendControl(.ack(update)); return
        }
        let repository = try Repository.ensure(name: update.repository, in: root)
        try configureRemote(for: repository)
        if let oid = update.oid {
            guard let pack else { throw SyncError.invalidProtocol("Object update has no pack") }
            try repository.install(pack: pack, target: oid)
        }
        let writer = try PeerRefWriter(repository: repository, peer: peer)
        try writer.apply(sourceRef: update.sourceRef, oid: update.oid)
        try writer.pruneExpired()
        try state.accept(generation: update.generation, peer: peer, epoch: epoch,
                         repository: update.repository, ref: update.sourceRef)
        sendControl(.ack(update))
        logger("\(update.repository): \(update.sourceRef) -> \(update.oid?.prefix(12) ?? "deleted")")
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
        lock.lock(); let known = peerKnown[repository.name]; lock.unlock()
        guard let known else { return [] }
        let updates = try state.updates(machine: machine, repository: repository.name,
                                        refs: repository.sourceRefs(), full: full)
            .filter { !excluded.contains($0.sourceRef) }
        for update in updates {
            let pack = try update.oid.map { try repository.pack(oid: $0, excluding: Array(known)) }
            try connection.send(update: update, pack: pack)
        }
        return Set(updates.map(\.sourceRef))
    }

    private func refreshCatalog() throws {
        let found = try Repository.discover(in: root).filter { includedRepositories?.contains($0.name) ?? true }
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
}
