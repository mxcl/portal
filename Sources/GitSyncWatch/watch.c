#include "GitSyncWatch.h"

#ifdef __APPLE__
#include <CoreServices/CoreServices.h>
#include <string.h>

struct callback_context {
    dispatch_semaphore_t semaphore;
    const char *const *paths;
    size_t count;
};

static const char *relative_path(const char *path, const char *parent) {
    size_t length = strlen(parent);
    while (length > 1 && parent[length - 1] == '/') length--;
    if (strncmp(path, parent, length) != 0) return NULL;
    if (path[length] == '\0') return path + length;
    if (length == 1 && parent[0] == '/') return path + 1;
    return path[length] == '/' ? path + length + 1 : NULL;
}

static int relevant_path(const struct callback_context *context, const char *path) {
    // Existing repositories (including bare repos and external worktree metadata).
    for (size_t i = 1; i < context->count; i++)
        if (relative_path(path, context->paths[i])) return 1;
    const char *relative = relative_path(path, context->paths[0]);
    if (!relative) return 1; // Conservatively handle an unexpected root event.
    const char *child = strchr(relative, '/');
    if (!child) return 1; // Root or immediate child: discovery/rename/removal.
    child++;
    // Initializing Git inside an existing directory must also trigger discovery.
    return strcmp(child, "HEAD") == 0 || strcmp(child, ".git") == 0 ||
           strncmp(child, ".git/", 5) == 0;
}

static void changed(ConstFSEventStreamRef stream, void *info, size_t count,
                    void *paths, const FSEventStreamEventFlags flags[],
                    const FSEventStreamEventId ids[]) {
    (void)stream; (void)ids;
    struct callback_context *context = info;
    const char *const *changed_paths = paths;
    for (size_t i = 0; i < count; i++) {
        if ((flags[i] & (kFSEventStreamEventFlagMustScanSubDirs |
                         kFSEventStreamEventFlagRootChanged |
                         kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)) ||
            relevant_path(context, changed_paths[i])) {
            dispatch_semaphore_signal(context->semaphore);
            return;
        }
    }
}

static void drained(void *unused) { (void)unused; }

int git_sync_wait_for_changes(const char *const *paths, size_t count, int timeout_ms) {
    if (!count) return 0;
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    if (!array) return -1;
    for (size_t i = 0; i < count; i++) {
        CFStringRef path = CFStringCreateWithCString(NULL, paths[i], kCFStringEncodingUTF8);
        if (path) { CFArrayAppendValue(array, path); CFRelease(path); }
    }

    struct callback_context context = { dispatch_semaphore_create(0), paths, count };
    FSEventStreamContext stream_context = { 0, &context, NULL, NULL, NULL };
    FSEventStreamRef stream = FSEventStreamCreate(
        NULL, changed, &stream_context, array, kFSEventStreamEventIdSinceNow,
        0.25, kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
    );
    CFRelease(array);
    if (!stream) { dispatch_release(context.semaphore); return -1; }

    dispatch_queue_t queue = dispatch_queue_create("dev.mxcl.git-sync.fsevents", DISPATCH_QUEUE_SERIAL);
    FSEventStreamSetDispatchQueue(stream, queue);
    int started = FSEventStreamStart(stream);
    long result = started
        ? dispatch_semaphore_wait(context.semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC))
        : 1;
    FSEventStreamStop(stream);
    FSEventStreamInvalidate(stream);
    // Finish callbacks before the stack context and caller-owned paths go away.
    dispatch_sync_f(queue, NULL, drained);
    FSEventStreamRelease(stream);
    dispatch_release(queue);
    dispatch_release(context.semaphore);
    return !started ? -1 : (result == 0 ? 1 : 0);
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
