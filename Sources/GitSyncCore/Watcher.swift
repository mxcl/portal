import Foundation
import GitSyncWatch

public enum Watcher {
    public static func wait(root: URL, repositories: [Repository], timeout: TimeInterval = 30) {
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
        let strings = Array(Set(urls.map(\.path)))
        let allocated = strings.map { strdup($0) }
        let pointers: [UnsafePointer<CChar>?] = allocated.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        defer { allocated.forEach { free($0) } }
        _ = git_sync_wait_for_changes(pointers, pointers.count, Int32(timeout * 1000))
    }
}
