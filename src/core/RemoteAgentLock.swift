#if os(macOS)
import Darwin
import Foundation

final class RemoteAgentLock: @unchecked Sendable {
    private let descriptor: Int32
    private let stateLock = NSLock()
    private var isReleased = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    static func acquire(
        path: String,
        waitingUpTo timeout: TimeInterval,
        retryMicroseconds: useconds_t = 10_000,
        onContention: @Sendable () -> Void = {}
    ) -> RemoteAgentLock? {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds.saturatingAdding(timeoutNanoseconds)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                close(descriptor)
                return nil
            }
            onContention()
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                close(descriptor)
                return nil
            }
            usleep(retryMicroseconds)
        }
        return RemoteAgentLock(descriptor: descriptor)
    }

    func release() {
        stateLock.lock()
        guard !isReleased else {
            stateLock.unlock()
            return
        }
        isReleased = true
        stateLock.unlock()
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private extension UInt64 {
    func saturatingAdding(_ value: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(value)
        return overflow ? .max : sum
    }
}
#endif
