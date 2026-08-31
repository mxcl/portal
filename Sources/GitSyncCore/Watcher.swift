import Foundation
import GitSyncWatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public struct Watcher {
    private let paths: [String]

    public init(root: URL, repositories: [Repository]) {
        var urls = [root]
        for repository in repositories {
            guard let common = repository.commonDirectory else { continue }
            urls.append(common)
            let refs = common.appendingPathComponent("refs", isDirectory: true)
            if let enumerator = FileManager.default.enumerator(at: refs, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    urls.append(url)
                }
            }
        }
        paths = Array(Set(urls.map(\.path)))
    }

    // ponytail: the native watch is recreated to observe session state; paths stay cached between events.
    public func wait(timeout: TimeInterval = 2) -> Bool {
        let allocated = paths.map { strdup($0) }
        let pointers: [UnsafePointer<CChar>?] = allocated.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        defer { allocated.forEach { free($0) } }
        return git_sync_wait_for_changes(pointers, pointers.count, Int32(timeout * 1000)) != 0
    }
}
