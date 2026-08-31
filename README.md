# git-sync

Continuously exchange Git history between your own computers over one
persistent SSH connection. `git-sync` implements a bidirectional, continuous
fetch/push system. Each host publishes snapshots of its refs into the other
host's peer namespace while both working repositories remain independent.
Incoming history leaves local branches, `HEAD`, the index, and working files
alone.

```console
$ git-sync run \
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
$ git log sync/linux/main
$ git diff main..sync/linux/main
```

Branches appear at `refs/remotes/sync/<machine>/…`, tags at
`refs/sync/<machine>/tags/…`, and stashes at
`refs/sync/<machine>/stash`.

Each enabled peer is also available as a Git remote named from its configured
machine name in lowercase kebab case, so ordinary commands such as
`git fetch linux` and `git push linux main` work over SSH. Git Sync configures
branch and tag fetch mappings without changing local branches or tags.

If both machines advance `main`, both histories are retained:

```text
machine A: refs/heads/main          machine B: refs/heads/main
           refs/remotes/sync/B/main           refs/remotes/sync/A/main
```

You decide when to merge, rebase, reset, check out, or incorporate a
peer ref, as you would after `git fetch`.

## Install the Mac app

```console
$ ./scripts/install.sh
```

This builds, Developer ID signs, and installs the menu-bar-only `Git Sync.app`
in `/Applications`. Open it and choose the one parent folder. Add each SSH host
before choosing folders; the app rejects the host if its Git Sync helper cannot
be inspected. The folder table is prepopulated from every host. Select both the
local and remote host cells to enable a folder in both directions. Matching
repository names already present on both hosts retain the initial “Are You
Sure?” confirmation.

The app launches at login and shows live transfer logs in its menu. It uses the
copy of `git-sync` inside each peer's `/Applications/Git Sync.app`; the path can
be changed while adding that host.

## Linux / CLI install

Swift 5.9 or newer and Git are required.

```console
$ swift build -c release
$ install .build/release/git-sync ~/.local/bin/git-sync
```

The peer needs ordinary SSH authentication. No listening socket, repository
hook, Git replacement, or filesystem mirroring is used. Git remains responsible
for object validation, packs, garbage collection, and atomic ref updates.

## Development

```console
$ swift test
```

See [DESIGN.md](DESIGN.md) for the protocol, state model, and failure analysis.
