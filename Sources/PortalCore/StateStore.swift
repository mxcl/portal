import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private struct StateDocument: Codable {
    var source: [String: StoredRef] = [:]
    var inbound: [String: UInt64] = [:]
    var sourceEpoch: String?
    var renames: Set<UUID>?
}

private final class StateFileLock {
    private let descriptor: Int32

    init(stateURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = stateURL.appendingPathExtension("lock")
        descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw SyncError.invalidConfiguration("Could not open state lock: \(lockURL.path)")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SyncError.invalidConfiguration("Another Portal process is using state: \(stateURL.path)")
        }
    }

    deinit { close(descriptor) }
}

public final class StateStore {
    private let url: URL
    private let fileLock: StateFileLock
    private let lock = NSLock()
    private var document: StateDocument
    let sourceEpoch: String

    public init(url: URL) throws {
        self.url = url
        fileLock = try StateFileLock(stateURL: url)
        if let data = try? Data(contentsOf: url) {
            document = try JSONDecoder().decode(StateDocument.self, from: data)
        } else {
            document = StateDocument()
        }
        if document.sourceEpoch == nil { document.sourceEpoch = UUID().uuidString }
        sourceEpoch = document.sourceEpoch!
        try Validator.epoch(sourceEpoch)
        try save()
    }

    public func applyRenames(_ records: [ProjectRename.Record]) throws {
        lock.lock(); defer { lock.unlock() }
        for record in records where record.complete && !(document.renames ?? []).contains(record.id) {
            // Discard historical state for a reused destination, then preserve the source generations.
            for key in Array(document.source.keys) where key.components(separatedBy: "\u{1f}")[1] == record.new {
                document.source.removeValue(forKey: key)
            }
            for key in Array(document.inbound.keys) where key.components(separatedBy: "\u{1f}")[2] == record.new {
                document.inbound.removeValue(forKey: key)
            }
            for key in Array(document.source.keys) {
                var parts = key.components(separatedBy: "\u{1f}")
                if parts[1] == record.old {
                    parts[1] = record.new
                    document.source[parts.joined(separator: "\u{1f}")] = document.source.removeValue(forKey: key)
                }
            }
            for key in Array(document.inbound.keys) {
                var parts = key.components(separatedBy: "\u{1f}")
                if parts[2] == record.old {
                    parts[2] = record.new
                    document.inbound[parts.joined(separator: "\u{1f}")] = document.inbound.removeValue(forKey: key)
                }
            }
            document.renames = (document.renames ?? []).union([record.id])
            try save()
        }
    }

    public func updates(machine: String, repository: String, refs: [String: String], full: Bool) throws -> [RefUpdate] {
        try Validator.machine(machine); try Validator.project(repository)
        lock.lock(); defer { lock.unlock() }
        let prefix = key(machine, repository, "")
        var changed = Set<String>()

        for (ref, oid) in refs {
            try Validator.sourceRef(ref); try Validator.oid(oid)
            let itemKey = key(machine, repository, ref)
            if document.source[itemKey]?.oid != oid {
                document.source[itemKey] = StoredRef(oid: oid, generation: (document.source[itemKey]?.generation ?? 0) + 1)
                changed.insert(itemKey)
            }
        }
        for itemKey in document.source.keys where itemKey.hasPrefix(prefix) {
            let ref = String(itemKey.dropFirst(prefix.count))
            if refs[ref] == nil, document.source[itemKey]?.oid != nil {
                document.source[itemKey]!.oid = nil
                document.source[itemKey]!.generation += 1
                changed.insert(itemKey)
            }
        }
        if !changed.isEmpty { try save() }

        return document.source.keys.filter { $0.hasPrefix(prefix) && (full || changed.contains($0)) }.sorted().compactMap {
            guard let stored = document.source[$0] else { return nil }
            return RefUpdate(repository: repository, sourceRef: String($0.dropFirst(prefix.count)), generation: stored.generation, oid: stored.oid)
        }
    }

    public func acceptedGeneration(peer: String, epoch: String, repository: String, ref: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return document.inbound[inboundKey(peer, epoch, repository, ref)] ?? 0
    }

    @discardableResult
    public func accept(generation: UInt64, peer: String, epoch: String,
                       repository: String, ref: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let itemKey = inboundKey(peer, epoch, repository, ref)
        guard generation > (document.inbound[itemKey] ?? 0) else { return false }
        document.inbound[itemKey] = generation
        try save()
        return true
    }

    private func key(_ machine: String, _ repository: String, _ ref: String) -> String {
        "\(machine)\u{1f}\(repository)\u{1f}\(ref)"
    }

    private func inboundKey(_ peer: String, _ epoch: String, _ repository: String, _ ref: String) -> String {
        "\(peer)\u{1f}\(epoch)\u{1f}\(repository)\u{1f}\(ref)"
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }
}
