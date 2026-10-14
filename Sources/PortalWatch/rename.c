#define _GNU_SOURCE
#include "PortalWatch.h"
#include <stdio.h>
#include <fcntl.h>
#if defined(__linux__)
#include <unistd.h>
#include <sys/syscall.h>
#endif

int portal_rename_exclusive(const char *source, const char *destination) {
#if defined(__APPLE__)
    return renamex_np(source, destination, RENAME_EXCL);
#else
    return syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, 1 /* RENAME_NOREPLACE */);
#endif
}
