#pragma once

#include <stddef.h>

// Persistent recursive filesystem observation. Paths may be added while
// servicing an event; events remain queued while the caller scans the filesystem.
typedef struct portal_observer portal_observer;
portal_observer *portal_observer_create(void);
int portal_observer_add(portal_observer *, const char *path);
// Linux: -1 recursively, 0 this directory, 1 this directory and immediate children.
int portal_observer_add_depth(portal_observer *, const char *path, int depth);
int portal_observer_wait(portal_observer *, int timeout_ms);
void portal_observer_destroy(portal_observer *);

// Drain the paths accumulated since the last call. "/" means rescan everything.
typedef void (*portal_path_callback)(const char *, void *);
void portal_observer_paths(portal_observer *, portal_path_callback, void *);

// Wait for client data or EOF. Zero means its lease expired.
int portal_wait_for_input(int descriptor, int timeout_ms);

// Atomic same-filesystem rename; never replaces an existing destination.
int portal_rename_exclusive(const char *source, const char *destination);
