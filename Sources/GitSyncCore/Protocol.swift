import Foundation

struct WireMessage: Codable {
    var type: String
    var machine: String?
    var repositories: [String]?
    var repository: String?
    var known: [String]?
    var update: RefUpdate?
    var oid: String?
    var message: String?

    static func hello(_ machine: String) -> WireMessage { WireMessage(type: "hello", machine: machine) }
    static func catalog(_ names: [String]) -> WireMessage { WireMessage(type: "catalog", repositories: names) }
    static func inventory(_ repository: String, known: [String]) -> WireMessage {
        WireMessage(type: "inventory", repository: repository, known: known)
    }
    static func update(_ update: RefUpdate) -> WireMessage { WireMessage(type: "update", update: update) }
    static func ack(_ update: RefUpdate) -> WireMessage {
        WireMessage(type: "ack", repository: update.repository, update: update, oid: update.oid)
    }
    static func error(_ message: String) -> WireMessage { WireMessage(type: "error", message: message) }
}

final class FramedConnection {
    static let json: UInt8 = 1
    static let pack: UInt8 = 2
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func send(_ message: WireMessage) throws {
        try send(kind: Self.json, data: JSONEncoder().encode(message))
    }

    func send(update: RefUpdate, pack: Data?) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try writeFrame(kind: Self.json, data: JSONEncoder().encode(WireMessage.update(update)))
        if let pack { try writeFrame(kind: Self.pack, data: pack) }
    }

    func send(kind: UInt8, data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try writeFrame(kind: kind, data: data)
    }

    func receiveMessage() throws -> WireMessage {
        let frame = try receiveFrame()
        guard frame.kind == Self.json else { throw SyncError.invalidProtocol("Expected control frame") }
        return try JSONDecoder().decode(WireMessage.self, from: frame.data)
    }

    func receivePack() throws -> Data {
        let frame = try receiveFrame()
        guard frame.kind == Self.pack else { throw SyncError.invalidProtocol("Expected pack frame") }
        return frame.data
    }

    private func writeFrame(kind: UInt8, data: Data) throws {
        guard data.count < Int(UInt32.max) else { throw SyncError.invalidProtocol("Frame is too large") }
        var length = UInt32(data.count + 1).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(kind)
        frame.append(data)
        try output.write(contentsOf: frame)
    }

    private func receiveFrame() throws -> (kind: UInt8, data: Data) {
        let header = try readExactly(4)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, length <= 1_073_741_824 else { throw SyncError.invalidProtocol("Invalid frame length") }
        let body = try readExactly(Int(length))
        return (body[body.startIndex], body.dropFirst())
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let chunk = try input.read(upToCount: count - result.count), !chunk.isEmpty else {
                throw SyncError.disconnected
            }
            result.append(chunk)
        }
        return result
    }
}
