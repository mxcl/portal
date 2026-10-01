// Build this file with observer.c and -I Sources/PortalWatch/include.
// On macOS add -framework CoreServices.
#include "PortalWatch.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>
#include <time.h>

static volatile sig_atomic_t interruptions;
static void interrupt_wait(int signal) {
    (void)signal;
    if (++interruptions == 20) alarm(0);
}
static void check_client_lease(void) {
    int channel[2]; assert(pipe(channel) == 0);
    signal(SIGALRM, interrupt_wait);
    struct itimerval timer = {{0, 20000}, {0, 20000}};
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    assert(setitimer(ITIMER_REAL, &timer, NULL) == 0);
    assert(portal_wait_for_input(channel[0], 40) == 0);
    clock_gettime(CLOCK_MONOTONIC, &end);
    alarm(0);
    long elapsed = (end.tv_sec - start.tv_sec) * 1000 + (end.tv_nsec - start.tv_nsec) / 1000000;
    assert(interruptions > 0 && elapsed < 250);
    assert(write(channel[1], "x", 1) == 1);
    assert(portal_wait_for_input(channel[0], 40) == 1);
    char byte; assert(read(channel[0], &byte, 1) == 1);
    close(channel[1]);
    assert(portal_wait_for_input(channel[0], 40) == 1); // EOF also wakes the lease.
    close(channel[0]);
}
static void saw_file(const char *path, void *context) {
    if (strstr(path, "/new/file")) *(int *)context = 1;
}
static void quiet(portal_observer *watch) {
    int result, count = 0;
    while ((result = portal_observer_wait(watch, 750)) == 1) assert(++count < 20);
    assert(result == 0);
}
int main(void) {
    check_client_lease();
    char root[] = "/tmp/gitinuum-observer-XXXXXX";
    assert(mkdtemp(root));
    portal_observer *watch = portal_observer_create();
    assert(watch && portal_observer_add(watch, root) == 0);
    quiet(watch);
    assert(portal_observer_wait(watch, 50) == 0);
    char directory[256], file[256];
    snprintf(directory, sizeof(directory), "%s/new", root);
    snprintf(file, sizeof(file), "%s/new/file", root);
    assert(mkdir(directory, 0700) == 0);
    assert(portal_observer_wait(watch, 3000) == 1);
    quiet(watch);
    for (int i = 0; i < 2; i++) {
        FILE *stream = fopen(file, "w");
        assert(stream); fprintf(stream, "%d", i); assert(fclose(stream) == 0);
        // Events written while the consumer was busy remain queued.
        assert(portal_observer_wait(watch, 3000) == 1);
        int found = 0;
        portal_observer_paths(watch, saw_file, &found);
        assert(found);
        quiet(watch);
    }
    portal_observer_destroy(watch);
    // Replication must not traverse unrelated build trees, including unreadable
    // directories. A recursive watch fails here on Linux as an ordinary user.
    char ignored[256];
    snprintf(ignored, sizeof(ignored), "%s/new/build", root);
    assert(mkdir(ignored, 0000) == 0);
    watch = portal_observer_create();
    assert(watch && portal_observer_add_depth(watch, root, 1) == 0);
    quiet(watch);
    FILE *stream = fopen(file, "w");
    assert(stream); fputs("discovery", stream); assert(fclose(stream) == 0);
    assert(portal_observer_wait(watch, 3000) == 1);
    portal_observer_destroy(watch);
    chmod(ignored, 0700); rmdir(ignored);
    unlink(file); rmdir(directory); rmdir(root);
    puts("PASS: recursive observation, queued writes, bounded discovery watches and idle silence");
}
