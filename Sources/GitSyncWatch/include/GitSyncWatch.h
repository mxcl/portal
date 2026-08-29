#pragma once

#include <stddef.h>

int git_sync_wait_for_changes(const char *const *paths, size_t count, int timeout_ms);
