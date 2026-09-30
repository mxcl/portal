#pragma once

#include <stddef.h>

int git_sync_wait_for_changes(const char *const *paths, size_t count, int timeout_ms);

// Persistent recursive observation for UI invalidation. Paths may be added while
// servicing an event; events remain queued while the caller scans the filesystem.
typedef struct git_sync_observer git_sync_observer;
git_sync_observer *git_sync_observer_create(void);
int git_sync_observer_add(git_sync_observer *, const char *path);
int git_sync_observer_wait(git_sync_observer *, int timeout_ms);
void git_sync_observer_destroy(git_sync_observer *);
