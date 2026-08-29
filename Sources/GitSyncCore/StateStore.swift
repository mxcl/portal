import Foundation

private struct StateDocument: Codable {
    var source: [String: StoredRef] = [:]
    var inbound: [String: UInt64] = [:]
}

public final class StateStore {
    private let url: URL
    private let lock = NSLock()
    private var document: StateDocument

    public init(url: URL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            document = try JSONDecoder().decode(StateDocument.self, from: data)
        } else {
            document = StateDocument()
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

    public func acceptedGeneration(peer: String, repository: String, ref: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return document.inbound[key(peer, repository, ref)] ?? 0
    }

    @discardableResult
    public func accept(generation: UInt64, peer: String, repository: String, ref: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let itemKey = key(peer, repository, ref)
        guard generation > (document.inbound[itemKey] ?? 0) else { return false }
        document.inbound[itemKey] = generation
        try save()
        return true
    }

    private func key(_ machine: String, _ repository: String, _ ref: String) -> String {
        "\(machine)\u{1f}\(repository)\u{1f}\(ref)"
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)
    }
}
