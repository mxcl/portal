#if os(macOS)
import Foundation
import GitSyncCore

/// One long-lived pipe per host. Blocking reads live on a utility queue; the
/// newest invalidation is retained while the main actor refreshes the inventory.
@MainActor
final class ProjectObservation {
    let identity: [String]
    private var task: Task<Void, Never>?
    private var process: Process?
    private var input: FileHandle?

    init(identity: [String], makeProcess: @escaping () throws -> Process,
         changed: @escaping () async throws -> Void, failed: @escaping (String) -> Void) {
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
                    let events = AsyncThrowingStream<Void, Error>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            do {
                                while true {
                                    _ = try BackupControlConnection.receive(ProjectChange.self,
                                        from: output.fileHandleForReading).checked()
                                    continuation.yield(())
                                }
                            } catch { continuation.finish(throwing: error) }
                        }
                    }
                    for try await _ in events {
                        guard !Task.isCancelled else { break }
                        try await changed()
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
