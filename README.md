# Portal

A native block terminal for Mac whose sessions survive closed tabs, app relaunches, and device changes.

[Download Portal for macOS][download]

> [!IMPORTANT]
> Portal 1.0 requires macOS 26.1 or newer. GitHub releases contain the Mac app; this repository also contains the iPhone app.

![Portal showing terminal sessions as command blocks](assets/screenshot1.webp)

## Install

1. Download the latest DMG.
2. Drag Portal to Applications.
3. Open it.

## Your shell keeps running

Portal renders each command and its output as a block while the shell runs in a separate `portal-sessiond` process.

Close a tab with `⌘W` and reopen it with `⌘⇧T`. Quit Portal and come back later. Typing `exit` ends the session; closing its window only detaches.

The new-tab screen lists every live session, including its working directory, recent command, and host.

![Portal session picker](assets/screenshot2.webp)

## Rejoin from another Mac or iPhone

Turn on **Remote Access** in the new-tab screen or the Portal menu. Macs signed in to the same Apple Account then appear in Portal on your other devices. You can attach to a live session or start a new one.

Portal creates the remote-access key on your device and syncs it through iCloud Keychain. Portal encrypts terminal traffic and session catalogs before they reach the relay. The Mac makes outbound connections; Portal opens no terminal listener on your LAN.

> [!WARNING]
> Read the [security model][security] and feel contented before enabling Remote Access.

The relay implementation and wire protocol are in this repository. Portal does not support self-hosted relays yet.

## Completions without shell setup

Portal combines executable names, shell builtins, command history, paths, and bundled [Fig completion specs][fig] as you type. The same completions work when you attach to another Mac.

> [!WARNING]
> Fig generators can execute shell code. A generator for a remote session runs as your user on that Mac. Use completion specs you trust.

## Build from source

You need macOS 26.1, Xcode, and Rust.

```sh
$ scripts/build.sh --debug --run
```

> [!NOTE]
> The full app build currently needs Portal's Developer ID Application identity and matching provisioning profile because the app authenticates its session daemon by code signature. You can build and test the Swift and Rust cores without them. You can run your own relay if you prefer… it’s not trivial tho.

Run the Swift and Rust tests:

```sh
$ swift test
$ cargo test
```

Protocol changes must also pass the release gate:

```sh
$ scripts/validate-protocol-compatibility.sh
```

For build, DMG, notarization, and publishing options:

```sh
$ scripts/build.sh --help
```

[download]: https://github.com/mxcl/portal/releases/latest
[fig]: https://github.com/withfig/autocomplete
[security]: docs/remote-access-threat-model.md
