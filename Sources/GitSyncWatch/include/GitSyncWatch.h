#pragma once

#include <stddef.h>

// Persistent recursive filesystem observation. Paths may be added while
// servicing an event; events remain queued while the caller scans the filesystem.
typedef struct git_sync_observer git_sync_observer;
git_sync_observer *git_sync_observer_create(void);
int git_sync_observer_add(git_sync_observer *, const char *path);
int git_sync_observer_wait(git_sync_observer *, int timeout_ms);
void git_sync_observer_destroy(git_sync_observer *);

// Drain the paths accumulated since the last call. "/" means rescan everything.
typedef void (*git_sync_path_callback)(const char *, void *);
void git_sync_observer_paths(git_sync_observer *, git_sync_path_callback, void *);
