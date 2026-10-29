# Portal

A beautiful, tasteful, delightful terminal. macOS native AF.

This repository contains two separate Mac apps:

- **[Portal][download]** is the terminal: command blocks, completions, and sessions that survive closed tabs and app relaunches.
- **[Portal Hub][hub-download]** is an experimental project manager with Git sync and backups across your computers.

Download either app separately. Both require macOS 26 or newer on Apple silicon.

## Portal · the terminal

[Download Portal for macOS][download], open the DMG, and drag **Portal.app** into Applications.

https://github.com/user-attachments/assets/c9829fa6-da3b-4339-a564-af6d8da1fb35

### Your shell keeps running

Portal renders each command and its output as a block. Your shell runs in a separate `portal-sessiond` process.

Close a tab with `⌘W` and reopen it with `⌘⇧T`. Quit Portal and come back later. Typing `exit` ends the session; closing its window only detaches.

The new-tab screen lists live sessions with their working directory, recent command, and host. Rejoin a session where you left it, with its output history intact.

### Rejoin from another Mac or iPhone

Start or rejoin sessions on your other computers over SSH. On Mac, Portal uses the hosts configured in Portal Hub. Install both apps to configure those destinations and open project terminals from Hub.

The repository also includes [Portal for iPhone](ios/README.md), which connects to Mac sessions over SSH on Tailscale or another private VPN. Follow its setup guide for SSH keys, pinned host keys, and network requirements.

For a Linux terminal host, install the persistent session helpers as well as any Git sync daemon you need:

```console
$ ./scripts/install-terminal-helpers.sh
```

Run this from a checkout on the Linux host with Rust installed. The helpers live in `~/.local/lib/portal/terminal`; `portald` handles Git sync separately.

### Completions without shell setup

Portal combines executable names, shell builtins, command history, paths, and bundled [Fig completion specs][fig] as you type. Completions also work in remote sessions.

> [!IMPORTANT]
> Fig generators can execute shell code. A generator for a remote session runs as your user on that host. Use completion specs you trust.

## Portal Hub · experimental project management & Git sync

[Download Portal Hub][hub-download] for project browsing, commit graphs, diffs, GitHub activity, continuous Git sync, and backups across your computers.

> [!WARNING]
> Portal Hub is experimental. Its project management and synchronization features are under active development.

Open **Portal Hub.app**, choose your projects folder, and add your SSH hosts. Select the local and remote host cells for each project you want to sync. Existing repositories with matching names require confirmation before enabling the connection.

Browse a project's history, README, and diffs even when it lives on another host. Hub reads remote repositories over SSH without requiring a local checkout. **New Terminal Window** opens the separate Portal terminal app.

### Your Git history, on your computers

`portald` continuously exchanges Git objects and ref snapshots over SSH. Each host keeps its own branches, tags, stash, `HEAD`, index, and working tree. Incoming branches appear under the peer's name:

```console
$ git log linux/main
$ git diff main..linux/main
```

Each enabled peer is also a Git remote. Ordinary `git fetch linux` and `git push linux main` work over SSH.

If both machines advance `main`, both histories are retained. You decide when to merge, rebase, or incorporate a peer's work.

**Keep matching clean checkouts in sync** opts both ends into guarded fast-forwards: the branch must match, both checkouts must be clean, and the local commit must be an ancestor of the peer tip. Divergent, staged, untracked, or otherwise dirty work stays untouched.

The menu helper keeps syncing when the project window is closed and shows live transfer logs. **Launch at Login** registers that helper.

### Back up and browse your projects

The Backup tab can continuously send your local repositories to another host. On the receiving Mac, choose **Receive Backups on This Mac** and a folder separate from your projects. Each backup is a bare Git repository; its refs are never published back to the source Mac.

Browse stored repositories, archive projects that no known host contains, or **Unarchive** a snapshot into your projects folder. Unarchive refuses to overwrite an existing repository.

The optional [GitHub integration](Relay/README.md) adds project notifications, star/PR/issue counts, and fetches triggered by GitHub pushes.

### Linux / CLI

Build and install the Git sync daemon with Swift 5.9 or newer and Git:

```console
$ swift build -c release --product portald
$ mkdir -p ~/.local/bin
$ install .build/release/portald ~/.local/bin/portald
$ portald run \
    --root ~/src \
    --machine macbook \
    --peer linux \
    --remote-root /home/max/src
```

Without `--selective`, every immediate Git repository under the root participates. Hub uses an explicit project selection. A missing selected project is initialized on the peer without checking out its files.

Saved Mac daemon paths should point to `/Applications/Portal Hub.app/Contents/Resources/portald`; Linux paths should point to `~/.local/bin/portald`. Legacy command names remain compatibility forwarders.

For the replication contract, ref namespaces, and failure handling, see [DESIGN.md](DESIGN.md). For CLI options, run `portald help`.

## Build from source

The Mac apps need Xcode, Rust, and the signing identity and provisioning profiles expected by the installer:

```console
$ ./scripts/install.sh
```

This builds, signs, and installs both **Portal.app** and **Portal Hub.app** in `/Applications`. The Swift and Rust tests can run without the app-signing setup:

```console
$ swift test
$ cargo test --manifest-path TerminalHelpers/Cargo.toml
```

## License

Portal is licensed under AGPL-3.0-or-later. Portal Hub's commit graph renderer is adapted from [MacGit](https://github.com/Commit-Plus/macgit); its original copyright and license notices are preserved in the source files.

[download]: https://github.com/mxcl/portal/releases/download/v1.0.0/Portal-1.0.0.dmg
[hub-download]: https://github.com/mxcl/portal/releases/download/v1.0.0/Portal-Hub-1.0.0.dmg
[fig]: https://github.com/withfig/autocomplete
