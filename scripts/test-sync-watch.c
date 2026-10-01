// macOS: clang -I Sources/PortalWatch/include scripts/test-sync-watch.c \
//   -framework CoreServices -o /tmp/test-sync-watch && /tmp/test-sync-watch
#include <assert.h>
#include "../Sources/PortalWatch/watch.c"

int main(void) {
    const char *paths[] = { "/src", "/src/project/.git", "/bare/repo.git", "/external/common" };
    struct callback_context context = { dispatch_semaphore_create(0), paths, 4 };
    const char *relevant[] = {
        "/src", "/src/new", "/src/removed", "/src/existing/.git",
        "/src/existing/.git/refs/heads/new", "/src/existing/HEAD",
        "/src/project/.git/packed-refs", "/src/project/.git/refs/heads/nested/main",
        "/src/project/.git/index", "/bare/repo.git/refs/tags/v1", "/external/common/refs/stash",
    };
    const char *irrelevant[] = {
        "/src/project/file.txt", "/src/excluded/build-output", "/src/project/.build/debug/output",
        "/src/project/.github/workflows/test.yml", "/src/project/.git-other/file",
    };
    for (size_t i = 0; i < sizeof(relevant) / sizeof(*relevant); i++)
        assert(relevant_path(&context, relevant[i]));
    for (size_t i = 0; i < sizeof(irrelevant) / sizeof(*irrelevant); i++)
        assert(!relevant_path(&context, irrelevant[i]));
    assert(relative_path("/src-other/file", "/src") == NULL);
    assert(strcmp(relative_path("/src/file", "/"), "src/file") == 0);

    const char *event[] = { "/src/excluded/build-output" };
    FSEventStreamEventFlags flag = kFSEventStreamEventFlagItemModified;
    changed(NULL, &context, 1, event, &flag, NULL);
    assert(dispatch_semaphore_wait(context.semaphore, DISPATCH_TIME_NOW) != 0);
    // Dropped/coalesced events must trigger a full scan, even outside Git metadata.
    flag |= kFSEventStreamEventFlagMustScanSubDirs;
    changed(NULL, &context, 1, event, &flag, NULL);
    assert(dispatch_semaphore_wait(context.semaphore, DISPATCH_TIME_NOW) == 0);
    dispatch_release(context.semaphore);
}
