---
name: deploy-everywhere
description: Build, sign, install, restart, and verify Portal on Max's Macs, Maliwan and pangolin, plus the atlas Linux SSH endpoint. Use when asked to deploy or install Portal everywhere from the current Portal checkout.
---

# Deploy Everywhere

Run the repository's deployment script from the `portal` checkout:

```bash
./scripts/deploy.sh /absolute/path/to/portal
```

The script detects whether it runs on Maliwan or pangolin, builds and signs `Portal Hub.app` and `Portal.app` release bundles there, and copies those exact bundles to the other Mac over SSH.
It also uses the matching open-source Swift toolchain at `~/.swiftly/bin/swift`
and the installed `aarch64-swift-linux-musl` SDK to cross-build a static binary
(`--product portald`) for `atlas`. It installs all three targets with rollback protection, restarts
Portal Hub and its menu helper at `/Applications/Portal Hub.app`, and verifies all five installed
Mac executables against the built bundle, plus the Linux executable hash.

The shared Mac installer launches the app with a minimal login environment on
both hosts. Keep that boundary intact: never forward the agent's environment
(including color, pager, terminal, or `CODEX_*` overrides) to the deployed app.
Preserve each Mac's session helper and its terminal sessions during deployment.
Stop the session helper only when the user explicitly requests it separately.

`atlas` is an SSH-launched `daemon --stdio` endpoint, not a persistent systemd
process. Install the `portald` build at `~/.local/bin/portald`; legacy `git-sync` and
`gitinuumd` command paths are forwarding scripts that exec `portald`. Do not create a service
unit unless a separate Atlas-initiated `run` configuration is explicitly
requested.

Deploy the invoking checkout as-is, including tracked or untracked changes. Do
not pull, reset, switch branches, copy the repository, or require a checkout on
the peer. Report the deployed revision and dirty state, then report success for
Maliwan, pangolin, and atlas separately. If a target fails, preserve successful
installs and report the failing command; do not clear caches, install toolchains,
or change signing settings.

The app executable is `PortalApp`; its login item is
`Portal Menu Helper.app` with service ID `dev.mxcl.portal.menu-helper`.
The Hub bundle contains `portald`, the `portal` launcher, and compatibility
forwarders for older command names. The standalone terminal is `/Applications/Portal.app`
with executable `PortalTerminalApp` and bundle ID `dev.mxcl.portal.terminal`. Keep these names aligned with `scripts/install.sh` and
`Package.swift` when updating deployment scripts.

For a read-only environment check, run:

```bash
./scripts/deploy.sh /absolute/path/to/portal --check
```

After deployment, verify bundle IDs and signatures, helper processes, and peer connectivity.
Saved Mac daemon paths must point to `/Applications/Portal Hub.app/Contents/Resources/portald`;
Linux paths should point to `~/.local/bin/portald`. Preserve live terminal session helpers.

The Atlas deployment also cross-builds the Rust terminal helpers with `cargo zigbuild`
for `aarch64-unknown-linux-musl` and installs them in `~/.local/lib/portal/terminal`.
Verify a new SSH terminal session, not just `portald`: terminal and Git sync use
separate executables. Preserve a live legacy daemon by sharing its existing state
and socket directory; never stop it during routine deployment.
