// Build this file with observer.c and -I Sources/GitSyncWatch/include.
// On macOS add -framework CoreServices.
#include "GitSyncWatch.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static void quiet(git_sync_observer *watch) {
    int result, count = 0;
    while ((result = git_sync_observer_wait(watch, 750)) == 1) assert(++count < 20);
    assert(result == 0);
}
int main(void) {
    char root[] = "/tmp/gitinuum-observer-XXXXXX";
    assert(mkdtemp(root));
    git_sync_observer *watch = git_sync_observer_create();
    assert(watch && git_sync_observer_add(watch, root) == 0);
    quiet(watch);
    assert(git_sync_observer_wait(watch, 50) == 0);
    char directory[256], file[256];
    snprintf(directory, sizeof(directory), "%s/new", root);
    snprintf(file, sizeof(file), "%s/new/file", root);
    assert(mkdir(directory, 0700) == 0);
    assert(git_sync_observer_wait(watch, 3000) == 1);
    quiet(watch);
    for (int i = 0; i < 2; i++) {
        FILE *stream = fopen(file, "w");
        assert(stream); fprintf(stream, "%d", i); assert(fclose(stream) == 0);
        // Events written while the consumer was busy remain queued.
        assert(git_sync_observer_wait(watch, 3000) == 1);
        quiet(watch);
    }
    git_sync_observer_destroy(watch);
    unlink(file); rmdir(directory); rmdir(root);
    puts("PASS: recursive observation, queued writes and idle silence");
}
