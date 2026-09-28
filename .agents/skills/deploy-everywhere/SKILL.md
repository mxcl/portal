---
name: deploy-everywhere
description: Build, sign, install, restart, and verify Gitinuum on Max's Macs, Maliwan and pangolin, plus the atlas Linux SSH endpoint. Use when asked to deploy or install Git Sync everywhere from the current git-sync checkout.
---

# Deploy Everywhere

Run the repository's deployment script from the `git-sync` checkout:

```bash
./scripts/deploy.sh /absolute/path/to/git-sync
```

The script detects whether it runs on Maliwan or pangolin, builds and signs one
`Gitinuum.app` release bundle there, and copies that exact bundle to the other Mac over SSH.
It also uses the matching open-source Swift toolchain at `~/.swiftly/bin/swift`
and the installed `aarch64-swift-linux-musl` SDK to cross-build a static binary
(`--product gitinuumd`) for `atlas`. It installs all three targets with rollback protection, restarts
both Mac apps at `/Applications/Gitinuum.app`, and verifies all four installed
Mac executables against the built bundle, plus the Linux executable hash.

The shared Mac installer launches the app with a minimal login environment on
both hosts. Keep that boundary intact: never forward the agent's environment
(including color, pager, terminal, or `CODEX_*` overrides) to the deployed app.
Preserve each Mac's session helper and its terminal sessions during deployment.
Stop the session helper only when the user explicitly requests it separately.

`atlas` is an SSH-launched `daemon --stdio` endpoint, not a persistent systemd
process. Install the `gitinuumd` build at `~/.local/bin/git-sync` for existing SSH
configurations; do not create a service
unit unless a separate Atlas-initiated `run` configuration is explicitly
requested.

Deploy the invoking checkout as-is, including tracked or untracked changes. Do
not pull, reset, switch branches, copy the repository, or require a checkout on
the peer. Report the deployed revision and dirty state, then report success for
Maliwan, pangolin, and atlas separately. If a target fails, preserve successful
installs and report the failing command; do not clear caches, install toolchains,
or change signing settings.

The app executable is `GitinuumApp`; its login item is
`Gitinuum Menu Helper.app` with service ID `dev.mxcl.git-sync.menu-helper`.
The bundle also contains `gitinuumd`, the `gitinuum` launcher, and a legacy
`git-sync` symlink. Keep these names aligned with `scripts/install.sh` and
`Package.swift` when updating deployment scripts.

For a read-only environment check, run:

```bash
./scripts/deploy.sh /absolute/path/to/git-sync --check
```
