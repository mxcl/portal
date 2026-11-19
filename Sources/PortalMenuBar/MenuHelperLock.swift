#if os(macOS)
import Darwin
import Foundation

func acquireMenuHelperLock(at url: URL) throws -> Int32? {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }

    let error = errno
    close(descriptor)
    if error == EWOULDBLOCK { return nil }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
}
#endif
