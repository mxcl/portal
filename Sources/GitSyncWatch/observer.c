#include "GitSyncWatch.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <pthread.h>

// Bounded event paths let consumers scan only affected projects. On overflow or
// allocation failure a root event conservatively requests a complete scan.
struct pending_paths { pthread_mutex_t lock; char **paths; size_t count; int all; };
static void record_path(struct pending_paths *pending, const char *path) {
    pthread_mutex_lock(&pending->lock);
    if (!pending->all) {
        if (pending->count == 4096) pending->all = 1;
        else {
            char **paths = realloc(pending->paths, (pending->count + 1) * sizeof(char *));
            if (!paths) pending->all = 1;
            else {
                pending->paths = paths;
                char *copy = strdup(path);
                if (!copy) pending->all = 1;
                else pending->paths[pending->count++] = copy;
            }
        }
    }
    pthread_mutex_unlock(&pending->lock);
}
static void drain_paths(struct pending_paths *pending, git_sync_path_callback callback, void *context) {
    pthread_mutex_lock(&pending->lock);
    if (pending->all && callback) callback("/", context);
    for (size_t i = 0; i < pending->count; i++) {
        if (!pending->all && callback) callback(pending->paths[i], context);
        free(pending->paths[i]);
    }
    free(pending->paths); pending->paths = NULL; pending->count = 0; pending->all = 0;
    pthread_mutex_unlock(&pending->lock);
}

#ifdef __APPLE__
#include <CoreServices/CoreServices.h>
struct observed_path { char *path; FSEventStreamRef stream; struct observed_path *next; };
struct git_sync_observer {
    struct pending_paths pending;
    dispatch_semaphore_t signal;
    dispatch_queue_t queue;
    struct observed_path *paths;
};
static void observed(ConstFSEventStreamRef stream, void *info, size_t count,
                     void *paths, const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    (void)stream; (void)flags; (void)ids;
    git_sync_observer *watch = info;
    const char *const *changed_paths = paths;
    for (size_t i = 0; i < count; i++) {
        int rescan = flags[i] & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                               kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount);
        record_path(&watch->pending, rescan ? "/" : changed_paths[i]);
    }
    dispatch_semaphore_signal(watch->signal);
}
git_sync_observer *git_sync_observer_create(void) {
    git_sync_observer *watch = calloc(1, sizeof(*watch));
    if (!watch) return NULL;
    pthread_mutex_init(&watch->pending.lock, NULL);
    watch->signal = dispatch_semaphore_create(0);
    watch->queue = dispatch_queue_create("git-sync.observer", DISPATCH_QUEUE_SERIAL);
    return watch;
}
int git_sync_observer_add(git_sync_observer *watch, const char *path) {
    for (struct observed_path *p = watch->paths; p; p = p->next) {
        size_t length = strlen(p->path);
        if (!strncmp(p->path, path, length) && (path[length] == '\0' || path[length] == '/')) return 0;
    }
    struct observed_path *p = calloc(1, sizeof(*p));
    if (!p) return -1;
    p->path = strdup(path);
    if (!p->path) { free(p); return -1; }
    CFStringRef text = CFStringCreateWithCString(NULL, path, kCFStringEncodingUTF8);
    if (!text) { free(p->path); free(p); return -1; }
    CFArrayRef paths = CFArrayCreate(NULL, (const void **)&text, 1, &kCFTypeArrayCallBacks);
    FSEventStreamContext context = {0, watch, NULL, NULL, NULL};
    p->stream = FSEventStreamCreate(NULL, observed, &context, paths,
        kFSEventStreamEventIdSinceNow, 0.5, kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents);
    CFRelease(paths); CFRelease(text);
    if (!p->stream) { free(p->path); free(p); return -1; }
    FSEventStreamSetDispatchQueue(p->stream, watch->queue);
    if (!FSEventStreamStart(p->stream)) {
        FSEventStreamInvalidate(p->stream); FSEventStreamRelease(p->stream);
        free(p->path); free(p); return -1;
    }
    p->next = watch->paths; watch->paths = p;
    return 0;
}
int git_sync_observer_wait(git_sync_observer *watch, int timeout_ms) {
    dispatch_time_t deadline = timeout_ms < 0 ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC);
    if (dispatch_semaphore_wait(watch->signal, deadline)) return 0;
    while (!dispatch_semaphore_wait(watch->signal, DISPATCH_TIME_NOW)) {}
    return 1;
}
static void observer_drained(void *unused) { (void)unused; }
void git_sync_observer_destroy(git_sync_observer *watch) {
    for (struct observed_path *p = watch->paths; p;) {
        struct observed_path *next = p->next;
        FSEventStreamStop(p->stream); FSEventStreamInvalidate(p->stream);
        dispatch_sync_f(watch->queue, NULL, observer_drained);
        FSEventStreamRelease(p->stream); free(p->path); free(p); p = next;
    }
    dispatch_release(watch->queue); dispatch_release(watch->signal);
    drain_paths(&watch->pending, NULL, NULL); pthread_mutex_destroy(&watch->pending.lock); free(watch);
}
#elif defined(__linux__)
#include <sys/inotify.h>
#include <sys/stat.h>
#include <poll.h>
#include <unistd.h>
#include <dirent.h>
#include <stdio.h>
struct observed_path { int wd; char *path; struct observed_path *next; };
struct git_sync_observer { struct pending_paths pending; int fd; struct observed_path *paths; };
git_sync_observer *git_sync_observer_create(void) {
    int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
    if (fd < 0) return NULL;
    git_sync_observer *watch = calloc(1, sizeof(*watch));
    if (!watch) { close(fd); return NULL; }
    pthread_mutex_init(&watch->pending.lock, NULL);
    watch->fd = fd; return watch;
}
int git_sync_observer_add(git_sync_observer *watch, const char *path) {
    struct stat info;
    if (lstat(path, &info)) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(info.st_mode)) return 0;
    int wd = inotify_add_watch(watch->fd, path, IN_CLOSE_WRITE | IN_CREATE | IN_DELETE |
        IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB | IN_DELETE_SELF | IN_MOVE_SELF);
    if (wd < 0) return -1;
    for (struct observed_path *p = watch->paths; p; p = p->next)
        if (p->wd == wd) return 0;
    struct observed_path *p = calloc(1, sizeof(*p));
    if (!p) return -1;
    p->wd = wd; p->path = strdup(path);
    if (!p->path) { free(p); return -1; }
    p->next = watch->paths; watch->paths = p;
    DIR *dir = opendir(path);
    if (!dir) return -1;
    int result = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char *child = malloc(strlen(path) + strlen(entry->d_name) + 2);
        if (!child) { result = -1; break; }
        sprintf(child, "%s/%s", path, entry->d_name);
        result = git_sync_observer_add(watch, child);
        free(child);
        if (result) break;
    }
    closedir(dir); return result;
}
int git_sync_observer_wait(git_sync_observer *watch, int timeout_ms) {
    struct pollfd fd = {watch->fd, POLLIN, 0};
    int ready;
    do { ready = poll(&fd, 1, timeout_ms); } while (ready < 0 && errno == EINTR);
    if (ready <= 0) return ready;
    char buffer[65536] __attribute__((aligned(__alignof__(struct inotify_event))));
    ssize_t size;
    while ((size = read(watch->fd, buffer, sizeof(buffer))) > 0) {
        for (char *cursor = buffer; cursor < buffer + size;) {
            struct inotify_event *event = (struct inotify_event *)cursor;
            // Reconnect and rescan rather than silently missing an overflow.
            if (event->mask & IN_Q_OVERFLOW) { errno = EOVERFLOW; return -1; }
            // A moved subtree invalidates descendant pathname mappings. Reconnect
            // with a fresh recursive watch rather than retain stale mappings.
            if (event->mask & IN_MOVE_SELF) { errno = ESTALE; return -1; }
            struct observed_path **link = &watch->paths;
            while (*link && (*link)->wd != event->wd) link = &(*link)->next;
            if (*link) {
                struct observed_path *p = *link;
                if (event->len) {
                    char *changed = malloc(strlen(p->path) + strlen(event->name) + 2);
                    if (!changed) return -1;
                    sprintf(changed, "%s/%s", p->path, event->name);
                    record_path(&watch->pending, changed); free(changed);
                } else record_path(&watch->pending, p->path);
                if (event->mask & (IN_IGNORED | IN_MOVE_SELF | IN_DELETE_SELF)) {
                    *link = p->next;
                    if (!(event->mask & IN_IGNORED)) inotify_rm_watch(watch->fd, p->wd);
                    free(p->path); free(p);
                } else if (event->len && (event->mask & IN_ISDIR) && (event->mask & (IN_CREATE | IN_MOVED_TO))) {
                    char *child = malloc(strlen(p->path) + strlen(event->name) + 2);
                    if (!child) return -1;
                    sprintf(child, "%s/%s", p->path, event->name);
                    int result = git_sync_observer_add(watch, child);
                    free(child);
                    if (result) return -1;
                }
            }
            cursor += sizeof(*event) + event->len;
        }
    }
    return size < 0 && errno != EAGAIN ? -1 : 1;
}
void git_sync_observer_destroy(git_sync_observer *watch) {
    close(watch->fd);
    for (struct observed_path *p = watch->paths; p;) {
        struct observed_path *next = p->next; free(p->path); free(p); p = next;
    }
    drain_paths(&watch->pending, NULL, NULL); pthread_mutex_destroy(&watch->pending.lock);
    free(watch);
}
#endif

void git_sync_observer_paths(git_sync_observer *watch, git_sync_path_callback callback, void *context) {
    drain_paths(&watch->pending, callback, context);
}
