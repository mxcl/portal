---
name: deploy-everywhere
description: Build, sign, install, restart, and verify Git Sync on Max's Macs, Maliwan and pangolin, plus the atlas Linux SSH endpoint. Use when asked to deploy or install Git Sync everywhere from the current git-sync checkout.
---

# Deploy Everywhere

Run the repository's deployment script from the `git-sync` checkout:

```bash
./scripts/deploy.sh /absolute/path/to/git-sync
```

The script detects whether it runs on Maliwan or pangolin, builds and signs one
release bundle there, and copies that exact bundle to the other Mac over SSH.
It also uses the matching open-source Swift toolchain at `~/.swiftly/bin/swift`
and the installed `aarch64-swift-linux-musl` SDK to cross-build a static binary
for `atlas`. It installs all three targets with rollback protection, restarts
both Mac apps, and verifies the installed executable hashes.

`atlas` is an SSH-launched `daemon --stdio` endpoint, not a persistent systemd
process. Install its binary at `~/.local/bin/git-sync`; do not create a service
unit unless a separate Atlas-initiated `run` configuration is explicitly
requested.

Deploy the invoking checkout as-is, including tracked or untracked changes. Do
not pull, reset, switch branches, copy the repository, or require a checkout on
the peer. Report the deployed revision and dirty state, then report success for
Maliwan, pangolin, and atlas separately. If a target fails, preserve successful
installs and report the failing command; do not clear caches, install toolchains,
or change signing settings.

For a read-only environment check, run:

```bash
./scripts/deploy.sh /absolute/path/to/git-sync --check
```
