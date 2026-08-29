import Foundation

public final class SyncSession {
    private let root: URL
    private let machine: String
    private let connection: FramedConnection
    private let state: StateStore
    private let logger: (String) -> Void
    private let lock = NSLock()
    private var peerMachine: String?
    private var peerKnown: [String: Set<String>] = [:]
    private var repositories: [String: Repository] = [:]
    private var stopped = false

    public init(root: URL, machine: String, input: FileHandle, output: FileHandle,
                stateURL: URL, logger: @escaping (String) -> Void = { _ in }) throws {
        try Validator.machine(machine)
        self.root = root
        self.machine = machine
        connection = FramedConnection(input: input, output: output)
        state = try StateStore(url: stateURL)
        self.logger = logger
    }

    public func run() throws {
        try refreshCatalog()
        try connection.send(.hello(machine))
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
                for repository in repositories.values { try sendUpdates(for: repository, full: false) }
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
                guard let peer = message.machine else { throw SyncError.invalidProtocol("HELLO has no machine") }
                try Validator.machine(peer)
                lock.lock(); peerMachine = peer; lock.unlock()
                logger("connected to \(peer)")
            case "catalog":
                for name in message.repositories ?? [] {
                    let repository = try Repository.ensure(name: name, in: root)
                    lock.lock(); repositories[name] = repository; lock.unlock()
                    try connection.send(.inventory(name, known: repository.knownOIDs()))
                }
            case "inventory":
                guard let name = message.repository, let known = message.known else {
                    throw SyncError.invalidProtocol("INVENTORY is incomplete")
                }
                try Validator.project(name)
                for oid in known { try Validator.oid(oid) }
                lock.lock(); peerKnown[name] = Set(known); let repository = repositories[name]; lock.unlock()
                if let repository { try sendUpdates(for: repository, full: true) }
            case "update":
                guard let update = message.update else { throw SyncError.invalidProtocol("UPDATE is incomplete") }
                let pack = update.oid == nil ? nil : try connection.receivePack()
                try receive(update, pack: pack)
            case "ack":
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
        try Validator.sourceRef(update.sourceRef)
        let peer = try currentPeer()
        if update.generation <= state.acceptedGeneration(peer: peer, repository: update.repository, ref: update.sourceRef) {
            try connection.send(.ack(update)); return
        }
        let repository = try Repository.ensure(name: update.repository, in: root)
        if let oid = update.oid {
            guard let pack else { throw SyncError.invalidProtocol("Object update has no pack") }
            try repository.install(pack: pack, target: oid)
        }
        let writer = try PeerRefWriter(repository: repository, peer: peer)
        try writer.apply(sourceRef: update.sourceRef, oid: update.oid)
        try writer.pruneExpired()
        try state.accept(generation: update.generation, peer: peer, repository: update.repository, ref: update.sourceRef)
        try connection.send(.ack(update))
        logger("\(update.repository): \(update.sourceRef) -> \(update.oid?.prefix(12) ?? "deleted")")
    }

    private func sendUpdates(for repository: Repository, full: Bool) throws {
        lock.lock(); let known = peerKnown[repository.name]; lock.unlock()
        guard let known else { return }
        for update in try state.updates(machine: machine, repository: repository.name,
                                        refs: repository.sourceRefs(), full: full) {
            let pack = try update.oid.map { try repository.pack(oid: $0, excluding: Array(known)) }
            try connection.send(update: update, pack: pack)
        }
    }

    private func refreshCatalog() throws {
        let found = try Repository.discover(in: root)
        lock.lock(); repositories = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) }); lock.unlock()
    }

    private func currentPeer() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let peerMachine else { throw SyncError.invalidProtocol("UPDATE arrived before HELLO") }
        return peerMachine
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func setStopped() { lock.lock(); stopped = true; lock.unlock() }
}
