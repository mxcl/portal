# CPU measurements — September 23, 2026

Compared release builds of baseline `975ea44` and `codex/cpu-battery` on an Apple
M3 Max running macOS 27.0. Two local daemons exchange framed messages over a Unix
socket pair, with checkout syncing enabled, one selected repository and 25
excluded directories per endpoint. All repositories and state are temporary.

| Workload | Before | After |
| --- | ---: | ---: |
| Six seconds idle: daemon + Git CPU | 0.002869 s | 0.002785 s |
| Idle Git launches | 0 | 0 |
| 24 unrelated writes over six seconds: CPU | 1.164647 s | 0.005110 s |
| Unrelated-write Git launches | 86 | 0 |
| Unrelated-write interrupt wakeups | 88 | 6 |
| Three replicated commits: CPU | 1.691156 s | 0.562894 s |
| Active-sync Git launches | 183 | 58 |
| Active-sync interrupt wakeups | 160 | 39 |
| Median commit propagation | 1.655 s | 0.537 s |

Active-sync CPU fell 67%; unrelated-write CPU fell over 99%. Quiet idle was
already inexpensive. Package-idle wakeup counts were too small (0–4 per phase)
to support a meaningful battery-life estimate. CPU and wakeups use macOS
`proc_pid_rusage`, including reaped Git children; Mach ticks are converted with
`mach_timebase_info`. Git's native Trace2 counts launches. Propagation starts
after each commit finishes and ends when its peer ref is readable.

The running installed daemon's sample showed repeated repository discovery.
The running app also showed SwiftUI refresh work during filesystem activity;
its UI watcher is unchanged by this patch. These local daemon measurements do
not establish a whole-app battery-life improvement or performance over SSH.

Changes:

- Apply repository selection before spawning Git discovery probes.
- Check checkout cleanliness only when there are refs to publish, and disable
  optional index writes in that read so it cannot trigger more filesystem work.
- Ignore ordinary worktree/build writes in the macOS sync watcher. Preserve Git
  metadata, new/removed project folders, repository initialization, and dropped
  events. Keep the existing five-minute recovery pass and checkout guards.
- Avoid recursively enumerating ref directories for already-recursive FSEvents;
  drain callbacks and release the native queue and semaphore after every wait.

Reproduce from this checkout:

```sh
swift build -c release --product gitinuumd
python3 scripts/measure-sync-cpu.py .build/release/gitinuumd --check
clang -Wall -Wextra -Werror -fsanitize=address,undefined \
  -I Sources/PortalWatch/include scripts/test-sync-watch.c \
  -framework CoreServices -o /tmp/test-sync-watch
/tmp/test-sync-watch
swift test
```

The benchmark checks zero Git launches during idle/unrelated writes, excluded
projects never invoking Git, successful replication, and unchanged destination
local branches. The native check covers discovery, bare/external metadata,
path boundaries, and dropped-event fallback; address/undefined sanitizers pass.

The full Swift test run passed 94 of 96 tests, including all 67 core tests.
`editorSyntaxResources` and `editorMarkdownHighlighting` fail on both this change
and the untouched baseline with the same 15 assertions: syntax queries are looked
up under the flat bundle path while this toolchain creates a Contents/Resources
bundle. This unrelated existing failure is not fixed here. No Linux runtime or
installed-app UI comparison was performed. Changes are committed in the isolated
worktree; the installed app has not been replaced.
