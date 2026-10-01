#if os(macOS)
import Foundation
import GitSyncCore

/// One long-lived pipe per host. Blocking reads live on a utility queue; the
/// newest complete state is retained while the main actor applies the inventory.
@MainActor
final class ProjectObservation {
    let identity: [String]
    private var task: Task<Void, Never>?
    private var process: Process?
    private var input: FileHandle?

    init(identity: [String], makeProcess: @escaping () throws -> Process,
         changed: @escaping (ProjectChange) async throws -> Void, failed: @escaping (String) -> Void) {
        self.identity = identity
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let process = try makeProcess()
                    let input = Pipe(), output = Pipe()
                    process.standardInput = input
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    self.process = process
                    self.input = input.fileHandleForWriting
                    // Renew the remote lease on the existing pipe, with no Git
                    // reads or additional SSH sessions.
                    let heartbeat = Task {
                        while !Task.isCancelled {
                            try input.fileHandleForWriting.write(contentsOf: Data([0]))
                            try await Task.sleep(for: .seconds(30))
                        }
                    }
                    defer { heartbeat.cancel() }
                    let events = AsyncThrowingStream<ProjectChange, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            do {
                                while true {
                                    let change = try BackupControlConnection.receive(ProjectChange.self,
                                        from: output.fileHandleForReading).checked()
                                    continuation.yield(change)
                                }
                            } catch { continuation.finish(throwing: error) }
                        }
                    }
                    for try await change in events {
                        guard !Task.isCancelled else { break }
                        try await changed(change)
                    }
                } catch {
                    if !Task.isCancelled { failed("Live project updates unavailable: \(error). Check the host and update Gitinuum if needed.") }
                }
                self.close()
                guard !Task.isCancelled else { return }
                // Reconnect after failure, never poll a healthy connection.
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; close() }
    private func close() {
        try? input?.close(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
#endif
