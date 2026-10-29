# Portal

[Portal](https://github.com/mxcl/portal/releases/download/v1.0.0/Portal-1.0.0.dmg) is the terminal app.
[Portal Hub](https://github.com/mxcl/portal/releases/download/v1.0.0/Portal-Hub-1.0.0.dmg) manages projects, syncing, and backups. Download either app separately.

Continuously exchange Git history between your own computers over one
persistent SSH connection. `portald` implements a bidirectional, continuous
fetch/push system. Each host publishes snapshots of its refs into the other
host's peer namespace while both working repositories remain independent by
default. Incoming history leaves local branches, `HEAD`, the index, and working
files alone unless guarded checkout syncing is explicitly enabled.

```console
$ portald run \
    --root ~/src \
    --machine macbook \
    --peer linux \
    --remote-root /home/max/src
```

Without `--selective`, every immediate child of `~/src` that Git recognizes as
a repository participates in the exchange. The Mac app always uses an explicit
selection. A missing selected project is initialized at the peer as an empty
folder containing `.git`; files are not checked out.

```console
$ git log linux/main
$ git diff main..linux/main
```

Branches appear at `refs/remotes/<lowercase-kebab-machine>/…`, tags at
`refs/sync/<machine>/tags/…`, and stashes at
`refs/sync/<machine>/stash`.

Each enabled peer is also available as a Git remote named from its configured
display name in lowercase kebab case (or its machine name when unnamed),
so ordinary commands such as
`git fetch linux` and `git push linux main` work over SSH. Portal configures
branch and tag fetch mappings without changing local branches or tags.

If both machines advance `main`, both histories are retained:

```text
machine A: refs/heads/main          machine B: refs/heads/main
           refs/remotes/b/main                refs/remotes/a/main
```

You decide when to merge, rebase, reset, check out, or incorporate a
peer ref, as you would after `git fetch`.

`--sync-checkouts` (or **Keep matching clean checkouts in sync** in the Mac app)
opts both ends of a connection into guarded fast-forwards. Portal advances a
checked-out branch only when that same branch is the peer's clean checkout, the
local checkout is clean, and its current commit is an ancestor of the peer tip.
Staged, unstaged, untracked, divergent committed work, and non-fast-forward
updates leave the checkout untouched. A checkout that becomes clean later
retries the fast-forward during reconciliation (within five minutes).

The optional [GitHub integration](Relay/README.md) adds project notifications,
star/open PR/open issue counts, and branch/tag fetches triggered by GitHub pushes.
It uses a separate relay and APNs, with no recurring GitHub polling.

## Install the Mac app

```console
$ ./scripts/install.sh
```

This builds, Developer ID signs, and installs `Portal Hub.app` and `Portal.app`
in `/Applications`. Portal includes its menu-bar Sync Helper. Both deploy scripts
install and verify both apps. Open Portal Hub and choose the one parent
folder. Add each SSH host before choosing folders; the app rejects the host if its Portal helper cannot
be inspected. The folder table is prepopulated from every host. Select both the
local and remote host cells to enable a folder in both directions. Matching
repository names already present on both hosts retain the initial “Are You
Sure?” confirmation.

The Backup tab can continuously send every local repository to one existing
host. On the receiving Mac, use the same tab to choose **Receive Backups on This
Mac**; that folder must differ from its projects folder. Portal Hub.app owns the
destination and the SSH process only relays encrypted protocol bytes, so Remote
Login does not need Full Disk Access. The connection is receive-only: refs
created inside the backup are never published back to the source Mac. Each
backup is a bare repository named `<repository>.git` directly inside the chosen
destination.

The Backup tab lists stored repositories on both the receiving Mac and Macs that
back up to it. Repositories that no known host contains can be marked archived
without moving or deleting their data. **Unarchive** transfers a selected
snapshot from the receiver into the projects folder on the Mac where the action
was chosen; it refuses to overwrite an existing repository.

Projects that are not on this Mac remain browsable. Portal reads their commit
graph, README, and selected commit diffs over SSH without creating a local mirror;
live repositories also expose their GitHub origin. When several live hosts or
backup snapshots contain the project, the graph toolbar identifies the source and
lets you switch it. A local repository always takes precedence and keeps the source
picker hidden.

The embedded helper owns continuous syncing and shows live transfer logs in its
menu, even while the project window is closed. The Launch at Login setting
registers only `Portal Menu Helper.app`, which shares the main app’s icon files. It uses the copy of `portald` inside each peer's
`/Applications/Portal Hub.app`; the path can be changed while adding that host.

**New Terminal Window** opens the sibling **Portal** app in Applications. It lists all terminal sessions, including project sessions. Install both apps to open terminals from Portal Hub.

Choose **Portal → Install Command Line Tool…** to install `portal` in
`/usr/local/bin`. The bundled installer opens in Terminal and requests your
administrator password via `sudo`. Run `portal` to open the app, or
`portal /path/to/repository` to select a project. `portal --sync-help` lists
the daemon commands. The app must remain
installed; run the menu installer again after an update to refresh the CLI.

Existing hosts configured with `/Applications/Git Sync.app/Contents/Resources/portald`
need their executable path updated after renaming the installed app.

The bundle keeps `git-sync` as a compatibility symlink to `portald` for older
installed launchers. New peer configurations use `portald`.

## Linux / CLI install

Swift 5.9 or newer and Git are required.

```console
$ swift build -c release
$ install .build/release/portald ~/.local/bin/portald
```

The peer needs ordinary SSH authentication. No network listener, repository
hook, Git replacement, or filesystem mirroring is used. macOS backup receivers
use owner-only local Unix sockets inside Application Support. Git remains
responsible for object validation, packs, garbage collection, and atomic ref
updates.

## Development

```console
$ swift test
```

See [DESIGN.md](DESIGN.md) for the protocol, state model, and failure analysis.

## License

Portal is licensed under AGPL-3.0-or-later. Its commit graph renderer is
adapted from [MacGit](https://github.com/Commit-Plus/macgit); the original
copyright and license notices are preserved in those source files.
