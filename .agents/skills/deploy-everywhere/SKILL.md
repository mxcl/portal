---
name: deploy-everywhere
description: Build, sign, install, restart, and verify Portal on Max's Macs, Maliwan and pangolin, the atlas Linux SSH endpoint, and the iPhone app via TestFlight. Use when asked to deploy or install Portal everywhere from the current Portal checkout.
---

# Deploy Everywhere

Run both the Mac/Linux deployment and the iPhone TestFlight upload from the same `portal` checkout. The shell script below handles only Mac/Linux; the iPhone steps are required separately:

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
Maliwan, pangolin, atlas, and iPhone separately. If a target fails, continue the independent targets, preserve successful
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


## iPhone (TestFlight)

Archive and upload `PortalMobileApp` using the signed-in Xcode account and
`ios/ExportOptions.plist`. This is the default iPhone deployment route; it does
not require a connected phone. Keep bundle ID `dev.mxcl.portal`, team
`ZU76A67LGU`, and the existing marketing version. The export options let Xcode
manage the uploaded build number.

From the checkout root, create a unique output directory and keep it for
inspection if archiving or uploading fails:

```bash
mobile_stage="$(mktemp -d /tmp/portal-mobile-deploy.XXXXXX)"
xcodebuild -project ios/PortalMobileApp/PortalMobileApp.xcodeproj \
  -scheme PortalMobileApp -destination 'generic/platform=iOS' \
  -archivePath "$mobile_stage/PortalMobile.xcarchive" \
  -allowProvisioningUpdates archive
```

Only after the archive succeeds, upload that exact archive:

```bash
xcodebuild -exportArchive \
  -archivePath "$mobile_stage/PortalMobile.xcarchive" \
  -exportOptionsPlist ios/ExportOptions.plist \
  -exportPath "$mobile_stage/export" -allowProvisioningUpdates
```

Confirm upload success from Xcode's result and report the uploaded version and
build number. An upload is not confirmation that Apple finished processing or
that the app was installed on the phone: report those states separately when
verified. Do not submit an App Store release as part of this workflow. If an
upload's outcome is uncertain, inspect its distribution logs or App Store
Connect before retrying, so a rerun does not create duplicate uploads.
The Mac/Linux `--check` mode above does not validate iPhone signing or upload
credentials.
