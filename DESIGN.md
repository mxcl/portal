# Design

## Product contract

`git-sync` implements a continuous bidirectional Git fetch/push system. Both
working repositories remain independent. Each host is authoritative for its
own branches, tags, stash, `HEAD`, index, and working tree. It publishes selected
local ref snapshots into a namespace owned by that host on its peer.

```text
A refs/heads/main  ->  B refs/remotes/sync/A/main
B refs/heads/main  ->  A refs/remotes/sync/B/main
```

`git-sync` does not negotiate ordinary user Git operations. Commits, rebases,
force pushes, branch deletion, garbage collection, and offline work remain
local operations. The replication module observes their durable results
through Git and publishes them. If both hosts move their local `main`, both
local branches and both peer views remain available until the user reconciles
them.

Ref ownership supplies safety. Background code never writes a ref owned by a
user or another host. Each destination ref update is atomic. A scan containing
several ref changes is outside one repository-wide transaction, so a peer may
observe part of that scan. The next reconciliation repairs interruption or
partial progress.

The design uses installed Git as the adapter for object validation, pack
creation and installation, ref locking, and ref transactions. A sync-aware Git
replacement could restrict online commands. It still could not make disconnected
multi-writer branches converge without choosing an ownership or conflict policy
for the user.

## Architecture

`git-sync run` owns one source parent and one long-lived
`ssh -T <peer> git-sync daemon --stdio …` child process. Both endpoints run the
same session engine, so repository discovery and ref transfer are symmetric on
that single full-duplex stream. macOS uses FSEvents and Linux uses inotify only
to wake the engine; every wake re-reads durable state through Git.

Only immediate child directories are projects. The child directory name is
the pairing key for this first version. A catalog message creates a missing
peer project with `git init <root>/<name>`, producing only `.git` and no
checkout. Names containing path separators, `.` or `..` are rejected.

The Mac app edits one JSON configuration and controls a per-user `launchd`
agent. The agent is the same headless executable used on Linux.

## Protocol

Frames are a four-byte network-order length, a one-byte kind, then payload.
Kind 1 is UTF-8 JSON control data; kind 2 is an unmodified Git pack stream.
Each direction has one serialized writer, so an update control frame and its
following pack cannot interleave.

1. Both sides send `hello(protocol version, machine, source epoch)` and
   `catalog(project names)`. An incompatible version, malformed epoch, duplicate
   hello, or control message before hello terminates the session.
2. A receiver initializes missing projects and replies with an `inventory` of
   object IDs already reachable from its refs.
3. The sender enumerates `refs/heads/*`, `refs/tags/*`, and `refs/stash` with
   `git for-each-ref`, assigns persistent generations, and sends each update.
4. For a non-deletion, `git pack-objects --stdout --revs --thin` sends the new
   object closure excluding peer-known tips, followed by the raw pack frame.
5. The receiver installs with `git index-pack --stdin --fix-thin`, verifies the
   target with `git cat-file -e`, then atomically publishes the peer ref using
   compare-and-swap `git update-ref`.
6. An `ack` advances the sender's peer-known tips. Duplicate or stale
   generations are acknowledged without replaying their mutation.

EOF or SSH failure tears down the session. `run` reconnects and repeats the
idempotent inventory exchange; no separate resume protocol is necessary.

## Repository and ref state

Paths are not sent as identity. Within a paired parent, the validated child
name identifies a project. Renaming is therefore a new project in v1; a future
explicit pairing database can replace this without changing the wire framing.

Source refs map through a closed API:

| Source | Destination |
| --- | --- |
| `refs/heads/x` | `refs/remotes/sync/<machine>/x` |
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
  names. The only mutation capability maps accepted source refs beneath the
  two sync namespaces.
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
- **Force push/divergence:** the peer ref moves; local heads remain independent.
- **Deletion:** the prior tip remains reachable in the expiry namespace for 30
  days, then ordinary Git GC may reclaim it.
- **SSH command execution:** configuration chooses the SSH target and remote
  executable. Dynamic repository/ref data is framed on stdin, never placed in
  a shell command.

The invariant is structural: background code has no function that writes a
working tree, index, `HEAD`, local branch, local tag, stash, or caller-selected
ref.

## Implementation plan

1. Git subprocess boundary, discovery, ref mapping, state, and tests.
2. Framed full-duplex session and persistent SSH reconnection.
3. Native FSEvents/inotify trigger.
4. SwiftUI controller, launch agent, and app installer.

Stable repository pairing identities, multiple peers, repository-wide atomic
snapshots, systemd packaging, promotion actions, and transfer optimizations stay
out until the proof of concept needs them. None may weaken the ownership
invariant above.
