# git-sync

Continuously copy Git history between your own computers over one persistent
SSH connection. Incoming history lands in peer refs; local branches, `HEAD`,
the index, and working files are never touched.

```console
$ git-sync run \
    --root ~/src \
    --machine macbook \
    --peer linux \
    --remote-root /home/max/src
```

Every immediate child of `~/src` that Git recognizes as a repository is
synchronized. A missing project is initialized at the peer as an empty folder
containing `.git`; files are not checked out. Before first sync, the Mac app
lists repository names already present on both machines and requires confirmation.

```console
$ git log sync/linux/main
$ git diff main..sync/linux/main
```

Branches appear at `refs/remotes/sync/<machine>/…`, tags at
`refs/sync/<machine>/tags/…`, and stashes at
`refs/sync/<machine>/stash`.

## Install the Mac app

```console
$ ./scripts/install.sh
```

This builds and installs `Git Sync.app` in `/Applications` and links its CLI
to `~/.local/bin/git-sync`. Open it, choose
the one parent folder, enter the SSH peer and its parent folder, then start the
background agent. Install `git-sync` on the peer too; it must be discoverable
by the remote SSH login as `git-sync` (or set an absolute remote executable in
the app).

## Linux / CLI install

Swift 5.9 or newer and Git are required.

```console
$ swift build -c release
$ install .build/release/git-sync ~/.local/bin/git-sync
```

The peer needs ordinary SSH authentication. No listening socket, repository
hook, Git remote, or filesystem mirroring is used.

## Development

```console
$ swift test
```

See [DESIGN.md](DESIGN.md) for the protocol, state model, and failure analysis.
