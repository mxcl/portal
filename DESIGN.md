# Design

## App UI

Gitinuum has a conventional foreground app and an embedded menu-bar helper. The
app owns one project browser window, a native three-column
`NavigationSplitView`: an alphabetical project sidebar, a commit graph, and
contextual detail. The interface is deliberately dense and
quiet, like Finder or Xcode; the colored commit lanes are its only expressive
visual element. System colors, materials, typography, spacing, controls, and
selection behavior remain canonical.

Branch and tag copies with the same name collapse to that name when all known
copies point to the same commit. Lane labels also consolidate branch copies matching this Mac’s copy even when
another destination differs; differing copies retain their host or remote qualifier.
Tag badges and commit details retain the all-copies rule. Branch labels
anchor at their own commits even on a shared lane; middots join only names at
the same SHA. Nearby labels truncate with an ellipsis before the next tip. Hovering a lane label
reveals every qualified branch name at that commit above the graph, with a black outline around the colored letters.
The first glyph stays anchored; the suffix expands upward along the same path and upper tangent.

The checked-out commit row has a thin, subdued system-accent outline, independent
of the native selection fill. Its accessibility value identifies it as checked out.

The trailing segmented control selects Info or Diff, with Editor and Terminal
available only while Staging is selected. Info shows project placement and README;
selecting a commit opens Diff. Selecting Staging opens the local editor: a native
file outline and CodeEditSourceEditor share a resizable split in the detail column,
keeping the commit lanes visible. Remote staging opens Diff. Terminal currently
offers the external terminal action while its embedded view is deferred. External
editor, Finder, Terminal, and GitHub actions are direct project toolbar buttons,
separated from Refresh by a fixed toolbar spacer. GitHub uses its official
Invertocat from https://brand.github.com/foundations/logo as a template asset.

The editor lists tracked and non-ignored untracked files, including deleted paths
for diff inspection. Green checkmarks identify staged files; orange marks identify
unstaged or untracked files; conflicts have a warning symbol. A file may show both
staged and unstaged marks. Separate diff choices compare saved work with the index
or the index with HEAD using the existing gitdiff renderer. Saving never stages.
The existing repository watcher refreshes file status and diffs.

Save and Command-S atomically save a regular UTF-8 file, preserving line endings.
The first editor supports files up to 2 MB; binary files, symlinks, and Git metadata
cannot be edited. Unsaved text survives tab switches; file/project switches and
window close/quit offer Save, Cancel, and Don't Save. Outside changes make Save
fail with the draft retained; Reload is explicit and also guards unsaved text.
Native AppKit alerts own these decisions, ProjectEditor owns the draft, and
RepositoryTextFile owns lossless reading and saving. Semantic AppKit colors own
editor syntax and status styling; no separate theme token system is introduced.

The menu-bar helper shows a Project Status section with each local repository's
branch and changed-file count (or clean/mirrored state). It refreshes on menu
appearance and during local discovery. Recent events live in an Events submenu.
Project rows open that project in the app; their status text stays dimmed.
The helper also owns the global Command–Option–backtick shortcut, enabled by
default, which opens or activates the main app. General settings can disable it
immediately; the helper persists this local preference in UserDefaults. Control
protocol v4 includes the preference in snapshots and accepts its toggle command.
Protocol v5 adds the notification-opened action for delayed inbox reconciliation.
GitHub sign-in uses the built-in relay endpoint; its control command takes no URL.

The sidebar shows green `+` and red `−` line counts for projects with known
uncommitted changes, summed across this Mac and configured hosts. Clean projects
omit the counts; binary-only changes show `+0 −0`. The existing 30-second discovery
refresh carries optional `workingChanges` in peer inventories and helper snapshots;
older hosts omit it. Counts reuse staging's staged, unstaged, and untracked diffs,
without loading commit history. This additive metadata leaves protocol versions,
ref ownership, per-ref atomicity, and eventual consistency unchanged.

A small amber dot after the project name and optional globe indicates differing
default-branch tips across checked-out hosts, or this Mac’s branch differing from its known
GitHub tracking tip. Other hosts’ GitHub tracking caches do not trigger the dot. The first known default branch from this Mac or a configured
checked-out host is compared; other branches and unknown defaults do not trigger it. A configured
GitHub upstream takes precedence over the same-name origin branch. Missing
counterparts and mirrors do not trigger the dot. Optional `branchTips` inventory
metadata carries these local-only observations on the existing discovery cycle;
older hosts omit it. The selected project uses the graph’s fresh snapshots for
sidebar branch tips and working changes, so repository-watcher updates do not wait
for discovery. Content snapshots carry optional `branchTips`; older snapshots fall
back to inventory. The indicator performs no fetch or GitHub API requests and
leaves the existing relay-triggered fetch/catch-up behavior unchanged.

The sidebar groups active and archived projects. A project is the shared name
of repositories observed across configured hosts and backup inventory. Rows
show host presence and operational state without treating normal Git divergence
as an error. The graph renders this Mac's local branches, received peer branches,
and tags. In the graph list, branch names label the lanes, while local and peer
tags appear as badges on the second row beside the author and commit SHA. HEAD badges are omitted. Branch names read upwards beside their colored lanes, bending with
the path, in small, tracked, uppercase system-monospaced text. Names at the same SHA
share a compact label with middot separators. Labels at different SHAs on a lane
remain separate and truncate to fit between their tips. A lone long label may
continue along the upper tangent; a 4-point gap separates the start of the text
from the lower tip. Branches in a repository on this Mac are labeled with this Mac’s configured
name (for example, `maliwan/main`), independently of received refs. Remote
repositories use the selected host’s name, and backup histories use the snapshot’s
source machine. Only identical
labels at the same commit are deduplicated; origin and other hosts remain visible. Text starts 5 points below its tip (or the incoming merge dot), with
8 points of clearance perpendicular to the lane. Glyph spacing is measured along
that parallel curve, with each glyph centered on its tangent. The current machine’s labels appear at the
top of each group, followed by other refs; each name reads upwards. Full original-case branch names remain in row tooltips and accessibility
values. `GraphBranchLabel` owns the 8-point type, 1.1-point tracking, and glyph
shapes; `BranchGraphRowCanvas` owns 24-point lanes, 1.2-point lines, and filled
lettering. This graph-only typographic treatment leaves other app text native.
Each available host checkout has a persistent, host-labeled Staging row immediately
above its own HEAD (or first when HEAD has no visible commit), connected to that HEAD
by a dashed line, with staged, unstaged, untracked, and conflicted file counts whenever present, or “Clean” when there are no changes.
Changed relative paths fill one secondary line, truncated at the trailing edge;
each path has green additions and red deletions where Git provides line counts.
Counts sum the staged and unstaged diffs, including untracked files. The tooltip
lists all paths and counts. Older hosts without file details retain the count summary.
Diff remains available with separate
Staged and Unstaged views, including untracked files, and reads from the selected
row's host. Local staging refreshes with the repository; peer staging uses existing
read-only project-content requests on project load, Refresh, and every 30 seconds
while history is visible. Unavailable hosts show a retry message instead of stale
staging. Peer rows open Diff and never expose the local Editor or Terminal. The row
and its selection remain when clean; mirrors and backups omit it.

The detail column keeps project placement visible above a scrolling README.
The overview omits the repeated project title and groups each host's menu above
its plain-text placement status. Hosts without a checkout have dimmed menus whose actions name the target host.
Absent hosts omit the placement line. Only the configured backup destination adds
“& backed up” when a stored snapshot exists, or “Backed up” when it has no checkout;
backup errors and details remain in help text. GitHub sits alongside hosts, dimmed
when no GitHub remote is available. Its status compares the selected host's current
branch with its last known GitHub tracking ref: up to date, ahead, behind, or both.
Missing refs, detached HEAD, and older snapshots show unknown status. The comparison
reads Git only; existing push-triggered fetches and repository watchers refresh it
without a new poll or fetch. The tooltip identifies the branch, host, and tracking ref.
Hosts report optional OS/model metadata through the existing inspection. macOS uses
its registered device-model type and NSWorkspace icon; Linux uses a server symbol.
Unknown models and older hosts retain the generic computer icon. These optional
fields preserve protocol compatibility and leave ref ownership, per-ref atomicity,
and eventual consistency unchanged. README help and accessibility retain the
selected content source without a separate “From” heading. These compact groups sit side by side when
space permits and stack in narrow panes using native fitting layouts.
Selecting a commit replaces the overview with graph metadata and its diff, not a
file browser. Remote-only projects remain discoverable and their Git history,
README, GitHub origin, and commit diffs are read on demand from a selected live
host or backup snapshot. These reads never create a local repository or mutate
the source.

When a commit has an off-screen file, the trailing header shows a compact file
index. Its native menu lists every changed path and jumps to the selected diff;
the first visible file is marked. The index hides when every file intersects the
viewport and updates as the user scrolls or resizes the window.
The diff header groups author, date, and source on one line, with abbreviated
commit and parent hashes beside references below. These rows stack when needed;
hash controls copy the full value and expose it in help and accessibility text.

The UI uses no custom palette or typography. Semantic system colors carry state,
SF Symbols accompany every status label, and monospaced system text is reserved
for source code, refs, and object IDs. It supports light, dark, increased-contrast, keyboard,
and VoiceOver behavior through native SwiftUI components.

## Product contract

`gitinuumd` implements a continuous bidirectional Git fetch/push system. By
default both working repositories remain independent. Each host is authoritative
for its own branches, tags, stash, `HEAD`, index, and working tree. It publishes
selected local ref snapshots into a namespace owned by that host on its peer.

```text
A refs/heads/main  ->  B refs/remotes/a/main
B refs/heads/main  ->  A refs/remotes/b/main
```

`gitinuumd` does not negotiate ordinary user Git operations. Commits, rebases,
force pushes, branch deletion, garbage collection, and offline work remain
local operations. The replication module observes their durable results
through Git and publishes them. If both hosts move their local `main`, both
local branches and both peer views remain available until the user reconciles
them.

An explicit checkout-sync option relaxes local checkout ownership only for a
guarded fast-forward. An update identifies the sender's current clean checkout.
The receiver advances the same checked-out branch only if its index and working
tree are clean and its current commit is an ancestor of the incoming commit.
Thus staged, unstaged, untracked, committed, or divergent work prevents
promotion. A clean checkout retries an earlier blocked fast-forward during the
next full reconciliation, bounded to five minutes. Enabling this option is the
required user action and applies to both ends of that connection; it defaults
off.

Ref ownership supplies safety. Outside the explicit checkout-sync fast-forward
and the backup-gated merged-branch cleanup described below, background code never
writes a ref owned by a user or another host. Each
destination ref update is atomic. A scan containing several ref changes is
outside one repository-wide transaction, so a peer may observe part of that
scan. The next reconciliation repairs interruption or partial progress.

The design uses installed Git as the adapter for object validation, pack
creation and installation, ref locking, and ref transactions. A sync-aware Git
replacement could restrict online commands. It still could not make disconnected
multi-writer branches converge without choosing an ownership or conflict policy
for the user.

## Managed Git remotes

After a peer identifies itself, Gitinuum adds it to each enabled local project
using its configured display name in lowercase kebab case (or its machine name
when unnamed), with URL
`<ssh-target>:<remote-root>/<project>`. The remote's
fetch mappings reuse the namespaces already owned by that peer; changing the
display name does not move refs or change protocol identity:

| Source | Destination |
| --- | --- |
| `refs/heads/*` | `refs/remotes/<lowercase-kebab-machine>/*` |
| `refs/tags/*` | `refs/sync/<machine>/tags/*` |

Automatic tag following is disabled and pruning is enabled. Stash remains a
background-only ref because ordinary Git fetch fails when an exact optional
source ref is absent. Configuration is repaired on reconnect; disabling or
removing a host leaves its remote in place. A user's `git push <remote>`
is an explicit Git operation and is outside the background replication contract.

## Architecture

Each `gitinuumd run` owns one source parent and one long-lived
`ssh -T <peer> gitinuumd daemon --stdio …` child process. Both endpoints run the
same session engine, so repository discovery and ref transfer are symmetric on
that single full-duplex stream. The embedded menu helper starts one such process
per host that has at least one enabled project. macOS uses FSEvents and Linux uses
inotify only to wake the engine; every wake re-reads durable state through Git.

On macOS, sync watches wake for Git metadata, immediate project-folder changes,
and repository initialization, rather than ordinary worktree/build-file writes.
Dropped or coalesced events still request a scan. The existing five-minute full
reconciliation repairs watcher gaps and retries opt-in checkout fast-forwards
after a dirty checkout becomes clean. Selected sessions exclude disabled projects
before invoking Git. Checkout-cleanliness reads never refresh the index, and are
only needed when publishing updates; unchanged refs require no working-tree scan.

Only immediate child directories are projects. The child directory name is
the pairing key for this first version. A session may carry an explicit project
allow-list; names outside it are neither advertised nor accepted. A catalog
message creates a missing enabled peer project with `git init <root>/<name>`,
producing only `.git` and no checkout. Names containing path separators, `.` or
`..` are rejected.

The menu helper stores one local root, a table of inspected SSH hosts, and a
folder selection matrix. Adding a host first runs its installed helper's `inspect`
command; an unreachable host, missing helper, invalid response, or incompatible
protocol is rejected before configuration changes. Inspection prepopulates the
matrix from repositories already present on each host. A project participates
disabling either cell stops both directions. Equal names already present at
both ends require explicit confirmation before the host is added.

An optional backup selects one inspected host. The receiving host separately
chooses a parent folder, distinct from its normal root, through Gitinuum.app.
The menu helper owns an owner-only Unix socket and a receive-only session rooted at that
user-selected folder. The SSH-launched helper only relays the framed byte stream
to that socket, so macOS attributes destination access to Gitinuum.app rather
than Remote Login. No network listener or additional credential is introduced.
The endpoint accepts catalogs, objects, and ref snapshots but never advertises
repositories or publishes its own refs back. Its ordering state has one writer
inside the receiving helper and can run beside ordinary bidirectional connections.
It stores each backup as a bare `<name>.git` repository directly beneath the
selected parent folder; backup storage never creates a checkout-shaped wrapper.
The receiving app persists the latest complete repository catalog from each
backup source. A stored repository absent from every known catalog can be
explicitly marked archived; offline or not-yet-observed sources leave its status
unknown rather than producing a false orphan. Archival is metadata only and never
moves or deletes the bare repository.

The archived project controls offer explicit permanent deletion of the backup and
all its snapshots. The initiating Mac requires Touch ID when biometrics are
available; missing hardware or enrollment shows a confirmation modal with Cancel
as the default action. Cancellation,
lockout, and authentication failure leave the backup intact. Backup-control v7
adds `delete` (engine-control v7 adds `deleteBackup`). The destination validates
the project name and freshly reads its snapshots, then checks complete absent
host catalogs under the catalog lock before deleting the bare repository and
invalidating its inventory entry. Active mirrors/checkouts and unknown sources
are rejected. This uses the latest reported host catalogs, not a distributed
lease: a host that recreates a project later may back it up again. Replication's
per-ref atomicity and eventual consistency are unchanged.


Archive inventory and metadata mutations are available to configured source Macs
through SSH and a second owner-only app socket. Unarchive is an explicit promotion
action on the Mac where it is chosen. The receiver exports a Git bundle for the
selected snapshot, and the initiating app restores it into a new repository under
its own normal project root, promoting that source's branches, tags, and stash
while retaining every source's peer refs. It refuses an existing destination name
and constructs the repository under a temporary sibling before atomically moving
it into place. Because `HEAD` is not replicated, `main`, then `master`, then the
first branch is selected for checkout.

The same control socket streams read-only graph, README, and diff payloads for an
individual backup snapshot. Snapshot branches and tags are projected as local refs
for presentation while peer refs remain labeled as peers; the stored bare repository
is not changed. Large payloads follow a bounded control header as raw bytes rather
than enlarging the control-message envelope.

### Merged-branch cleanup

Settings → GitHub contains “Automatically delete merged branches”, a per-Mac
preference stored by the menu helper and defaulting to off, including upgrades.
Engine control protocol v7 carries this preference and its setter. Disabled cleanup
leaves relay work pending and stops its filesystem watcher; enabling it retries
pending work. The preference is rechecked after backup confirmation before deletion.

On opted-in connected Macs, new verified GitHub `pull_request` events with `action=closed`
and `merged=true` authorize cleanup of the source branch, including squash and
rebase merges. The original PR head SHA is the identity; ancestry of the resulting
merge commit is irrelevant. The relay stores each PR/head independently per device
in SQLite schema v2. Completed records remain as deduplication tombstones. It does
not sweep historical PRs, delete GitHub branches, or initiate cleanup on Linux.

Each Mac matches the source repository, branch name, and exact tip. Default/base
branches, symbolic refs, changed tips, and branches tracking a different upstream
are skipped. Branches in any checkout,
rebase, or bisect are deferred, as is cleanup while paused or without a usable
backup. Pending events survive relay/client restarts. Backup progress, local
status changes, configuration changes, and existing GitHub refresh triggers retry
pending work; failures use the existing bounded retry schedule.

The backup-control endpoint (protocol v7, independent of replication protocol v5)
accepts `retainMergedBranch`. Update backup receivers before clients; mismatched
control versions fail closed and prevent cleanup. Normal replication must first
supply the objects. The receiver rejects shallow/alternate-backed history, checks
reachable objects with Git, and creates an annotated tag under
`refs/sync/<machine>/merged/<event UUID>/heads/<branch>`. Its JSON message preserves
the project, source Mac, GitHub repository identities, original branch and tip,
local branch configuration, PR number, and merge timestamp. These refs never
expire and are excluded from the existing expired-ref pruning namespace.

Only a verified matching retention receipt permits the source to recheck eligibility
and delete using Git's expected-old-OID ref transaction with no symbolic dereference.
A concurrent tip change fails the transaction; checkout protection is checked again
immediately before deletion, like Git's own branch deletion, without locking out
ordinary Git commands. HEAD, index, worktree, and branch configuration are untouched.
This is a narrow exception to local-ref ownership, not permission to promote peer
refs or reconcile divergent branches. Replication still provides per-ref atomicity
and eventual snapshot consistency; a later ordinary update publishes the deletion.

Retention and deletion are deliberately separate: a crash may leave an extra backup
or an undeleted branch, never require deletion before retention. Requests replay
idempotently; an absent branch is already complete. Restore manually by inspecting
`git cat-file tag <retained-ref>` in the backup and creating a branch from
`<retained-ref>^{commit}` (or fetching that ref into another repository). Git GC
keeps the retained commit, trees, blobs, and original history reachable indefinitely.

The foreground app registers the embedded menu helper as its per-user login item.
The menu helper is the sole writer of configuration, starts the bundled headless
`gitinuumd` executable, and writes one connection and ordering-state file per host.
The app communicates with it through a separately versioned, owner-only control
socket; notifications only tell the app to request a fresh snapshot. The same
headless executable is used on Linux.

## Protocol

Frames are a four-byte network-order length, a one-byte kind, then payload.
Kind 1 is UTF-8 JSON control data; kind 2 is an unmodified Git pack stream.
Each direction has one serialized writer, so an update control frame and its
following pack cannot interleave.

1. Both sides send `hello(protocol version, machine, source epoch)` and
   `catalog(enabled project names)`. An incompatible version, malformed epoch, duplicate
   hello, or control message before hello terminates the session.
2. A receiver initializes missing projects and replies with an `inventory` of
   object IDs already reachable from its refs.
3. The sender enumerates `refs/heads/*`, `refs/tags/*`, and `refs/stash` with
   `git for-each-ref`, assigns persistent generations, and sends each update.
   With checkout syncing enabled, it marks an update only when that branch is
   its current clean checkout.
4. For a non-deletion, `git pack-objects --stdout --revs --thin` sends the new
   object closure excluding peer-known tips, followed by the raw pack frame.
5. The receiver installs with `git index-pack --stdin --fix-thin`, verifies the
   target with `git cat-file -e`, then atomically publishes the peer ref using
   compare-and-swap `git update-ref`. If guarded checkout syncing is enabled and
   every checkout guard passes, Git performs a fast-forward merge of the same
   checked-out local branch.
6. An `ack` advances the sender's peer-known tips. Duplicate or stale
   generations are acknowledged without replaying their mutation.

A receive-only endpoint sends an empty catalog, persists each incoming complete
catalog, answers it with inventories, and applies updates normally. It has no
filesystem watcher or outbound update path.

EOF or SSH failure tears down the session. `run` reconnects and repeats the
idempotent inventory exchange; no separate resume protocol is necessary. Before
each backup connection, the SSH helper checks the receiving app's local socket,
so a stopped app or unavailable destination fails once instead of reconnecting
indefinitely.

## Repository and ref state

Paths are not sent as identity. Within a paired parent, the validated child
name identifies a project. Renaming is therefore a new project in v1; a future
explicit pairing database can replace this without changing the wire framing.

Source refs map through a closed API:

| Source | Destination |
| --- | --- |
| `refs/heads/x` | `refs/remotes/<lowercase-kebab-machine>/x` |
| `refs/tags/x` | `refs/sync/<machine>/tags/x` |
| `refs/stash` | `refs/sync/<machine>/stash` |

No receiver API accepts a destination ref. Deleted refs move atomically to
`refs/sync/<machine>/expired/<unix>/<generation>/<kind>/<name>` and are pruned
after 30 days. Object deletion is never transmitted.

Generation state is JSON stored outside repositories under the configured
state directory. It records the last source value for each
`(machine, project, source ref)` and the last accepted value for each
`(machine, source epoch, project, source ref)`. A new epoch prevents sender
state loss from making its reset generation numbers permanently stale at the
receiver. Writes use atomic file replacement, and an advisory lock permits one
process to own a state file.

## Threat and failure analysis

- **Compromised peer:** it may send arbitrary bytes, names, and object IDs.
  Project/machine/ref inputs are validated; Git validates packs and object
  names. A selective session rejects repositories outside its allow-list. The
  only mutation capability maps accepted source refs beneath the two sync namespaces.
- **Interrupted/corrupt pack:** `index-pack` fails without publishing a ref.
  Already installed unreachable objects are harmless.
- **Crash after pack install:** restart repeats the transfer and publication.
- **Concurrent Git/GC:** Git owns pack installation and ref locking. A failed
  compare-and-swap is retried by the next inventory exchange.
- **Reordered/duplicate update:** persisted generation rejects it.
- **Sender state reset:** a new source epoch creates a fresh generation
  namespace, so the receiver accepts the next full reconciliation.
- **Duplicate process:** the second process fails to acquire the state lock
  instead of racing state writes and peer refs.
- **Incompatible peer:** the versioned hello fails before catalog or ref data is
  accepted.
- **Force push/divergence:** the peer ref moves; local heads remain independent,
  including when checkout syncing is enabled.
- **Deletion:** the prior tip remains reachable in the expiry namespace for 30
  days, then ordinary Git GC may reclaim it.
- **SSH command execution:** configuration chooses the SSH target and remote
  executable. Replication data is framed on stdin. Administrative and read-only
  commands accept validated child names and object IDs as individually shell-quoted
  arguments.
- **Opt-in checkout syncing:** a peer can fast-forward the current local branch
  only while both checkouts are clean and the local tip is an ancestor of the
  peer tip. Dirty state, divergent committed work, branch changes, and
  non-fast-forwards leave the checkout untouched; transient dirty state retries
  during reconciliation.
- **Local backup relay:** both Unix sockets live in the user's Application
  Support directory with mode `0600`. The app supplies the configured root;
  control requests contain validated repository and snapshot identities, never
  paths or destination refs. Exported bundles stream through the authenticated
  SSH session.

The default invariant is structural: background code has no function that writes
a working tree, index, `HEAD`, local branch, local tag, stash, caller-selected
ref, or Git configuration outside the configured lowercase-kebab remote. The
single opt-in exception is the guarded fast-forward above; it cannot create a
branch, switch branches, merge divergent history, or overwrite local changes.

## Implementation plan

1. Git subprocess boundary, discovery, ref mapping, state, and tests.
2. Framed full-duplex session and persistent SSH reconnection.
3. Native FSEvents/inotify trigger.
4. SwiftUI controller, launch agent, and app installer.

Stable repository pairing identities, repository-wide atomic snapshots,
systemd packaging, promotion actions, and transfer optimizations stay out until
the proof of concept needs them. None may weaken the ownership invariant above.

## GitHub integration

The optional GitHub connection uses a separate Gitinuum relay and the macOS menu
helper. APNs is a wake-up hint, not an event log: the relay retains per-device,
per-repository work until acknowledged. Each replacement work item has a fresh
UUID, so acknowledging older work cannot erase a newer event, including after a
relay state reset. GitHub repository work is event-driven; launch, wake, reconnect, initial
setup and explicit Refresh trigger catch-up. Inbox-only checks also run after
notification clicks and every minute while unread notifications remain. Local
discovery timers must not become GitHub polling timers.

With GitHub connected, branch events may fetch into `refs/remotes/<remote>/*`
for a matching, configured github.com remote in a local checkout. This is a
narrow exception to peer-only background ref writes. The fetch uses an explicit
branch refspec, never the configured remote refspecs. Tag push/create events also
queue fetch work. For a matching GitHub `origin`, each fetch (including catch-up)
also fetches `refs/tags/*:refs/tags/*` in a separate non-pruning, non-forced fetch.
This additional exception creates local tags but never replaces or deletes existing
tags; conflicting tags report a fetch error and leave work pending for retry.
Tag deletion events do not queue work. Other GitHub remotes fetch only branches.
Neither fetch writes `FETCH_HEAD`, local branches, stash, HEAD, index or working files.
Symbolic tag destinations are rejected. Peer
namespace collisions, mirror remotes and symbolic refs escaping the destination
namespace are rejected. Git retains responsibility for ref locking and updates;
per-ref atomicity and eventual consistency remain unchanged. Pausing sync defers
these fetches. No incoming commit is promoted into local work.

Peer inventory optionally includes GitHub repository identities; older peers
without this field remain readable. Counts are stars, open pull requests and open
issues (excluding PRs). Only active tracked projects receive notifications.

The menu bar icon shows a 6-point blue dot at its upper-right corner when the
last successful GitHub inbox snapshot contains unread notifications for tracked
repositories. Its 22-by-18-point image keeps the same size with and without the
dot, preserves the paused symbol, and includes unread status in its accessible
label. Opening the menu does not mark notifications read. Reading on GitHub
clears the dot after the next successful inbox refresh. While the dot is present,
the helper requests an inbox refresh every 60 seconds; it stops when unread state
clears. Opening a banner or menu notification schedules a check after three
seconds, coalescing repeated clicks. Each sync requests inbox reconciliation via
the optional `refreshInbox` flag, without enqueuing counts or repository fetches.
The relay enforces the shared per-user `X-Poll-Interval` / retry deadline, including
for clicks and pushes; triggers never bypass this limit. Inbox reconciliation
invalidates the conditional timestamp so read-only changes are observed.
The relay preserves history separately from unread state, retains unread state
on conditional 304 responses or failed refreshes, and reports it independently
of the 200-item history limit. The optional `hasUnreadNotifications` field keeps
older relay responses and local caches readable (unknown state shows no dot).


## Embedded terminals

`PortalTerminal` imports Portal's AppKit ANSI renderer, command blocks, shell
completion engine and persistent PTY sessions. Its public boundary is
`TerminalWorkspace`, `TerminalHost` and `TerminalCommands`. The workspace owns
controllers by project and host, so switching panes does not destroy a shell.
Output parsing and replay live in `TerminalOutputProcessor`; rendering does not
implement transport or session ownership. Portal's phone/iCloud relay, launcher
and updater are not included. The original Portal repository remains independent.

`gitinuum-sessiond` owns PTYs independently of the app. The app connects through
`gitinuum-session-bridge`, locally or through `/usr/bin/ssh -T`. Configured Gitinuum
hosts provide the SSH destination and project root. SSH uses existing config,
agent and known-hosts entries, requires verified host keys and runs noninteractively.
An unavailable connection retries with capped backoff. Reattachment joins the
existing session and restores history, screen and input modes; it never resends
input or silently creates a replacement shell. A confirmed shell exit ends retry.
Closing a used tab or the app detaches; Exit Terminal Session explicitly terminates
the shell. A host reboot or daemon exit ends its sessions.

macOS local sockets authenticate the peer's audit token with Security.framework,
requiring the expected Developer ID team and bundle identifiers on both ends.
Linux uses owner-only runtime storage and same-UID peer credentials. SSH authenticates
the remote host and account, not the originating application's code signature;
another process running as that account can invoke the signed bridge. These are
local helper identity checks, not cross-host application attestation.

Runtime and per-project catalog files use Gitinuum's own Application Support
directory (Linux: `$XDG_STATE_HOME/gitinuum-terminal`). Each catalog has one
controller writer. The terminal wire protocol negotiates versions 1 and 2 and
rejects unsupported versions independently of the Git replication protocol.
Terminal commands are explicit user actions; importing this module does not
change background Git ref ownership or the replication contract.

`scripts/install.sh` builds and signs the bundled Rust helpers and packages the
pinned Fig completion specifications. Rust/Cargo is required in addition to Swift.
On Linux, run `scripts/install-terminal-helpers.sh` in this checkout; it installs
the pair under `~/.local/lib/gitinuum/terminal`. macOS peers need the updated app.
No helper is uploaded or installed automatically when a connection is opened.

Validation: `swift test`, `cargo test --manifest-path TerminalHelpers/Cargo.toml`,
`scripts/test-terminal-peer-authentication.sh /path/to/Gitinuum.app`, and
`python3 scripts/test-terminal-sessions.py /path/to/Gitinuum.app` (or the Linux
helper directory). The session check exercises detach, continued execution,
history replay, reattach and exit against both wire versions.


## Backup inventory refresh

The destination helper shares one in-memory `BackupIndex` inventory between its
UI and remote backup control requests. Ordinary discovery reads this cache;
read-only control requests do not schedule another local refresh. Catalog changes
update placement metadata without rescanning repositories. Incoming ref writes
and local backup passes invalidate the affected repositories, which are reread on
the next inventory request. Inventory scans are serialized so concurrent clients
share the result and invalidations arriving during a scan are not lost.

The first read after startup, explicit Refresh, and the first read at least one
hour after the last full scan rebuild the inventory. The hourly pass catches
external additions, removals, and edits. A missing destination reports an error
even when an inventory is cached; failed scans are retried on subsequent requests.
Single-project history, diff, export, and restore reads inspect only that backup.
The optional `refresh` field on a version-7 backup list request requests a full
scan; older version-6 servers ignore it and retain their uncached behavior.
Git replication, per-ref atomicity, and eventual consistency are unchanged.

The GitHub notification menu shows only explicitly unread entries, keeping the
newest update per GitHub thread (issue, pull request, or other subject). Read
entries are hidden regardless of GitHub's Done state; unknown legacy read state
is hidden until refreshed. The relay prioritizes unread entries before applying
its history limit, so read history cannot crowd them out. Banner eligibility
also requires unread state; history IDs remain available for deduplication.
