#if os(macOS)
import CoreServices
import Foundation

/// A persistent recursive watch, owned and delivered on the main actor.
@MainActor
public final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor () -> Void

    /// Resolve off the main actor: linked worktrees can keep Git metadata outside their root.
    public nonisolated static func paths(for repository: URL) throws -> [String] {
        let metadata = try Git.text(["-C", repository.path, "rev-parse", "--path-format=absolute",
                                     "--git-dir", "--git-common-dir"])
        return Array(Set(([repository.path] + metadata.split(separator: "\n").map(String.init))
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }))
    }

    public init(paths: [String], onChange: @escaping @MainActor () -> Void) throws {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            // FSEvents delivers this stream exclusively on DispatchQueue.main.
            MainActor.assumeIsolated {
                Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue().changed()
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
           0.1, FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) else {
            throw SyncError.invalidConfiguration("Could not create the repository filesystem watcher.")
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw SyncError.invalidConfiguration("Could not start the repository filesystem watcher.")
        }
        self.stream = stream
    }

    private func changed() {
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            self?.onChange()
        }
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
#endif
