# Design

## Product contract

`git-sync` implements a continuous bidirectional Git fetch/push system. By
default both working repositories remain independent. Each host is authoritative
for its own branches, tags, stash, `HEAD`, index, and working tree. It publishes
selected local ref snapshots into a namespace owned by that host on its peer.

```text
A refs/heads/main  ->  B refs/remotes/a/main
B refs/heads/main  ->  A refs/remotes/b/main
```

`git-sync` does not negotiate ordinary user Git operations. Commits, rebases,
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

Ref ownership supplies safety. Outside the explicit checkout-sync fast-forward,
background code never writes a ref owned by a user or another host. Each
destination ref update is atomic. A scan containing several ref changes is
outside one repository-wide transaction, so a peer may observe part of that
scan. The next reconciliation repairs interruption or partial progress.

The design uses installed Git as the adapter for object validation, pack
creation and installation, ref locking, and ref transactions. A sync-aware Git
replacement could restrict online commands. It still could not make disconnected
multi-writer branches converge without choosing an ownership or conflict policy
for the user.

## Managed Git remotes

After a peer identifies itself, Git Sync adds it to each enabled local project
using its configured machine name in lowercase kebab case, with URL
`<ssh-target>:<remote-root>/<project>`. The remote's
fetch mappings reuse the namespaces already owned by that peer:

| Source | Destination |
| --- | --- |
| `refs/heads/*` | `refs/remotes/<lowercase-kebab-machine>/*` |
| `refs/tags/*` | `refs/sync/<machine>/tags/*` |

Automatic tag following is disabled and pruning is enabled. Stash remains a
background-only ref because ordinary Git fetch fails when an exact optional
source ref is absent. Configuration is repaired on reconnect; disabling or
removing a host leaves its remote in place. A user's `git push <machine>`
is an explicit Git operation and is outside the background replication contract.

## Architecture

Each `git-sync run` owns one source parent and one long-lived
`ssh -T <peer> git-sync daemon --stdio …` child process. Both endpoints run the
same session engine, so repository discovery and ref transfer are symmetric on
that single full-duplex stream. The Mac app starts one such process per host
that has at least one enabled project. macOS uses FSEvents and Linux uses
inotify only to wake the engine; every wake re-reads durable state through Git.

Only immediate child directories are projects. The child directory name is
the pairing key for this first version. A session may carry an explicit project
allow-list; names outside it are neither advertised nor accepted. A catalog
message creates a missing enabled peer project with `git init <root>/<name>`,
producing only `.git` and no checkout. Names containing path separators, `.` or
`..` are rejected.

The Mac app stores one local root, a table of inspected SSH hosts, and a folder
selection matrix. Adding a host first runs its installed helper's `inspect`
command; an unreachable host, missing helper, invalid response, or incompatible
protocol is rejected before configuration changes. Inspection prepopulates the
matrix from repositories already present on each host. A project participates
in a connection only when both the local and remote host cells are selected, so
disabling either cell stops both directions. Equal names already present at
both ends require explicit confirmation before the host is added.

An optional backup selects one inspected host. The receiving host separately
chooses a parent folder, distinct from its normal root, through Git Sync.app.
The app owns an owner-only Unix socket and a receive-only session rooted at that
user-selected folder. The SSH-launched helper only relays the framed byte stream
to that socket, so macOS attributes destination access to Git Sync.app rather
than Remote Login. No network listener or additional credential is introduced.
The endpoint accepts catalogs, objects, and ref snapshots but never advertises
repositories or publishes its own refs back. Its ordering state has one writer
inside the receiving app and can run beside ordinary bidirectional connections.
It stores each backup as a bare `<name>.git` repository directly beneath the
selected parent folder; backup storage never creates a checkout-shaped wrapper.
The receiving app persists the latest complete repository catalog from each
backup source. A stored repository absent from every known catalog can be
explicitly marked archived; offline or not-yet-observed sources leave its status
unknown rather than producing a false orphan. Archival is metadata only and never
moves or deletes the bare repository.

Archive inventory and metadata mutations are available to configured source Macs
through SSH and a second owner-only app socket. Unarchive is an explicit promotion
action on the Mac where it is chosen. The receiver exports a Git bundle for the
selected snapshot, and the initiating app restores it into a new repository under
its own normal project root, promoting that source's branches, tags, and stash
while retaining every source's peer refs. It refuses an existing destination name
and constructs the repository under a temporary sibling before atomically moving
it into place. Because `HEAD` is not replicated, `main`, then `master`, then the
first branch is selected for checkout.

The app controls its own per-user login item and writes one connection and
ordering-state file per host. The bundled helper is the same headless executable
used on Linux.

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
  executable. Dynamic repository/ref data is framed on stdin, never placed in
  a shell command.
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
