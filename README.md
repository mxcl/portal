# Vaultty

`Vaultty` is a macOS block terminal for Automic Vault workflows.

The app owns command input and renders command output as blocks. It uses a
persistent shell process and private OSC lifecycle markers.

![Vaultty screenshot](assets/screenshot1.webp)

![Vaultty screenshot](assets/screenshot2.webp)

## Features

- The macOS Tahoe appearance you’ve been waiting for.
  Proper (occluding) blur, vibrancy, and translucency.
- [Warp](https://warp.dev) style blocks
- [Fig](https://fig.io) autocompletions †
- [libghostty](https://github.com/mitchellh/ghostty) as the tty layer
- Persistent shell sessions that survive closed tabs and app quits

> [!WARNING]
>
> † Vaultty currently executes bundled Fig completion generator commands through
> `/bin/zsh -lc` for compatibility with specs that rely on shell quoting, pipes,
> redirects, and command syntax. Completion specs and custom generators can
> therefore execute shell code. This is a known security hole; the intended fix
> is to sandbox or otherwise constrain completion execution without breaking Fig
> compatibility.

## Sessions Survive Tabs

Closed tabs persist until you type `exit`. This means you can unclose tabs with
⌘⇧T. Even after restarting the app. Even across different machines.

Tabs detach from a Vaultty-owned `vaultty-sessiond` helper. The helper keeps the
PTY alive, and Vaultty can rejoin it later with terminal history and session
metadata.

New tabs show existing sessions above the command bar. Pick one to join it; the
fresh shell created for that new tab is discarded.

## Remote Sessions

Vaultty can also list and attach to sessions owned by your Unix account on
configured SSH hosts. The app does not open a LAN terminal listener and does not
store SSH passwords or private keys; SSH host keys, agent keys, and account
authorization remain the trust boundary.

Use `Sessions > Manage SSH Hosts...` to add a host. Enrollment verifies:

```sh
ssh -o BatchMode=yes -T user@host 'vaultty-session-bridge --version'
```

If the bridge is missing, Vaultty saves the host as unenrolled and shows an
install command. The remote side needs both helpers in the same directory:

```sh
vaultty-session-bridge
vaultty-sessiond
```

Once enrolled, remote sessions appear in the new-tab session picker alongside
local sessions. Each enrolled host also has a **New session** card that starts
a fresh login shell in the remote account's home directory. Attaching is a full
terminal attach over `ssh -T`; the remote `vaultty-session-bridge` proxies the
existing Vaultty line protocol to the remote user's private
`vaultty-sessiond` Unix socket.

Remote Vaultty shells intercept the `code` command:

```sh
code .
code src/app/TerminalViewController.swift
```

When you run `code PATH` in a session attached from another Mac, Vaultty opens
VS Code on the Mac in front of you with the matching Remote SSH folder or file.
VS Code's `code` command and Remote SSH extension must be installed locally.

## Build

```sh
scripts/build.sh --release
```

The build script signs the app with the first installed Developer ID Application
identity, or the identity specified by `CODESIGN_IDENTITY`.

## Versioning

`Cargo.toml` is the source of truth. By default, `scripts/build.sh --publish` asks Codex
for release notes and the next semantic version based on changes since the last
release, updates `Cargo.toml` and `Cargo.lock`, commits `vX.Y.Z`, pushes the
branch, then publishes GitHub release tag `vX.Y.Z` from the built app bundle.
With `--clobber`, it rebuilds and replaces the existing GitHub release for the
current Cargo version without asking Codex for notes or a new version.
`scripts/build.sh` stamps the Cargo version into `CFBundleShortVersionString`
and sets `CFBundleVersion` from the git commit count.

## Ghostty Integration

```sh
scripts/build-libghostty-vt.sh
scripts/build.sh --release --with-ghostty-vt
```

`libghostty-vt` is pinned to Ghostty `v1.3.1`, whose `build.zig.zon` requires
Zig `0.15.2`. `scripts/fetch-zig-0.15.2.sh` downloads the official arm64 macOS
Zig tarball and verifies its SHA-256 checksum. If Zig `0.15.2` cannot link
against the installed macOS SDK, the Ghostty build fails loudly and logs to
`target/logs/libghostty-vt-build.log` instead of silently shipping a terminal
that only pretends to use Ghostty.
