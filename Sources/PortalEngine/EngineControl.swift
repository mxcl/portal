#if os(macOS)
import Foundation
import PortalCore

public enum EngineClient {
    public static func send(_ command: EngineCommand) async throws -> EngineReply {
        try await Task.detached(priority: .userInitiated) {
            let connection = try LocalBackupTransport.connect(
                mode: LocalBackupTransport.session,
                to: EngineControlProtocol.socketURL
            )
            defer { try? connection.close() }
            try BackupControlConnection.send(EngineRequest(command: command), to: connection)
            return try BackupControlConnection.receive(EngineReply.self, from: connection)
        }.value
    }
}

public final class EngineControlServer: @unchecked Sendable {
    private let listener: LocalBackupListener
    private let queue = DispatchQueue(label: "portal.engine-control")

    public init() throws {
        listener = try LocalBackupListener(url: EngineControlProtocol.socketURL)
    }

    @MainActor
    public func start(model: EngineModel) {
        queue.async { [listener] in
            while true {
                let connection: FileHandle
                do {
                    connection = try listener.accept()
                } catch {
                    return
                }
                do {
                    let mode = try LocalBackupTransport.mode(from: connection)
                    guard mode == LocalBackupTransport.session else {
                        try? connection.close()
                        continue
                    }
                    let request = try BackupControlConnection.receive(EngineRequest.self, from: connection)
                    Task { @MainActor in
                        let reply: EngineReply
                        if request.version == EngineControlProtocol.version {
                            reply = await model.handle(request.command)
                        } else {
                            reply = EngineReply(error: "Unsupported engine control protocol version: \(request.version)")
                        }
                        try? BackupControlConnection.send(reply, to: connection)
                        try? connection.close()
                    }
                } catch {
                    try? BackupControlConnection.send(
                        EngineReply(error: "Invalid engine control request: \(error.localizedDescription)"),
                        to: connection
                    )
                    try? connection.close()
                }
            }
        }
    }

    public func stop() {
        listener.close()
    }
}
#endif
