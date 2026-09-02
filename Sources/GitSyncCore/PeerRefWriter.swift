import Foundation

public struct PeerRefWriter {
    public let repository: Repository
    public let peer: String

    public init(repository: Repository, peer: String) throws {
        try Validator.machine(peer)
        self.repository = repository
        self.peer = peer
    }

    @discardableResult
    public func apply(sourceRef: String, oid: String?, syncCheckout shouldSyncCheckout: Bool = false) throws -> Bool {
        let destination = try destinationRef(sourceRef)
        if let oid {
            try Validator.oid(oid)
            let old = current(destination) ?? String(repeating: "0", count: oid.count)
            _ = try Git.run(["-C", repository.url.path, "update-ref", destination, oid, old])
            return shouldSyncCheckout && syncCheckout(sourceRef: sourceRef, from: old, to: oid)
        } else if let old = current(destination) {
            let expired = try expiredRef(sourceRef)
            let transaction = "start\ncreate \(expired) \(old)\ndelete \(destination) \(old)\nprepare\ncommit\n"
            _ = try Git.run(["-C", repository.url.path, "update-ref", "--stdin"], input: Data(transaction.utf8))
        }
        return false
    }

    public func destinationRef(_ sourceRef: String) throws -> String {
        try Validator.sourceRef(sourceRef)
        if sourceRef == "refs/stash" { return "refs/sync/\(peer)/stash" }
        if sourceRef.hasPrefix("refs/heads/") {
            return "refs/remotes/\(Validator.remote(peer))/\(sourceRef.dropFirst("refs/heads/".count))"
        }
        return "refs/sync/\(peer)/tags/\(sourceRef.dropFirst("refs/tags/".count))"
    }

    public func pruneExpired(olderThan cutoff: Date = Date().addingTimeInterval(-30 * 86_400)) throws {
        let prefix = "refs/sync/\(peer)/expired/"
        let output = try Git.text(["-C", repository.url.path, "for-each-ref", "--format=%(refname)%00%(objectname)", prefix])
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\0", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let ref = String(fields[0]), parts = ref.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)
            if let seconds = parts.first.flatMap({ TimeInterval($0) }), Date(timeIntervalSince1970: seconds) < cutoff {
                _ = try Git.run(["-C", repository.url.path, "update-ref", "-d", ref, String(fields[1])])
            }
        }
    }

    private func current(_ ref: String) -> String? {
        let value = try? Git.text(["-C", repository.url.path, "rev-parse", "--verify", "-q", ref])
        return value?.isEmpty == false ? value : nil
    }

    private func syncCheckout(sourceRef: String, from old: String, to new: String) -> Bool {
        guard sourceRef.hasPrefix("refs/heads/"),
              current("HEAD") == old,
              (try? Git.text(["-C", repository.url.path, "symbolic-ref", "--quiet", "HEAD"])) == sourceRef,
              repository.cleanCheckoutRef() == sourceRef,
              Git.succeeds(["-C", repository.url.path, "merge-base", "--is-ancestor", old, new]) else {
            return false
        }
        return Git.succeeds(["-C", repository.url.path, "merge", "--ff-only", "--no-edit", "--no-autostash", new])
    }

    private func expiredRef(_ sourceRef: String) throws -> String {
        let suffix: String
        if sourceRef == "refs/stash" { suffix = "stash" }
        else if sourceRef.hasPrefix("refs/heads/") { suffix = "heads/" + sourceRef.dropFirst("refs/heads/".count) }
        else { suffix = "tags/" + sourceRef.dropFirst("refs/tags/".count) }
        return "refs/sync/\(peer)/expired/\(Int(Date().timeIntervalSince1970))/\(UUID().uuidString)/\(suffix)"
    }
}
