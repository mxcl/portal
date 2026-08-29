#include "GitSyncWatch.h"

#ifdef __APPLE__
#include <CoreServices/CoreServices.h>

struct callback_context {
    dispatch_semaphore_t semaphore;
};

static void changed(ConstFSEventStreamRef stream, void *info, size_t count,
                    void *paths, const FSEventStreamEventFlags flags[],
                    const FSEventStreamEventId ids[]) {
    (void)stream; (void)count; (void)paths; (void)flags; (void)ids;
    dispatch_semaphore_signal(((struct callback_context *)info)->semaphore);
}

int git_sync_wait_for_changes(const char *const *paths, size_t count, int timeout_ms) {
    if (!count) return 0;
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    if (!array) return -1;
    for (size_t i = 0; i < count; i++) {
        CFStringRef path = CFStringCreateWithCString(NULL, paths[i], kCFStringEncodingUTF8);
        if (path) { CFArrayAppendValue(array, path); CFRelease(path); }
    }

    struct callback_context context = { dispatch_semaphore_create(0) };
    FSEventStreamContext stream_context = { 0, &context, NULL, NULL, NULL };
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL, changed, &stream_context, array, kFSEventStreamEventIdSinceNow,
        0.25, kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
    );
    CFRelease(array);
    if (!stream) return -1;

    dispatch_queue_t queue = dispatch_queue_create("dev.mxcl.git-sync.fsevents", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(stream, queue);
    int started = FSEventStreamStart(stream);
    long result = started
        ? dispatch_semaphore_wait(context.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC))
        : 1;
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    FSEventStreamRelease(stream);
    return result != 0 ? 0 : (started ? 1 : -1);
}

#elif defined(__linux__)
#include <sys/inotify.h>
#include <poll.h>
#include <unistd.h>

int git_sync_wait_for_changes(const char *const *paths, size_t count, int timeout_ms) {
    int fd = inotify_init1(IN_CLOEXEC);
    if (fd < 0) return -1;
    int watches = 0;
    uint32_t mask = IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_MOVED_FROM |
                    IN_MOVED_TO | IN_ATTRIB;
    for (size_t i = 0; i < count; i++)
        if (inotify_add_watch(fd, paths[i], mask) >= 0) watches++;
    if (!watches) { close(fd); return 0; }

    struct pollfd poll_fd = { fd, POLLIN, 0 };
    int result = poll(&poll_fd, 1, timeout_ms);
    close(fd);
    return result < 0 ? -1 : (result > 0 ? 1 : 0);
}
#endif
