---
name: deploy-here
description: Build, sign, install, restart, and verify Gitinuum on the current Mac only. Use when asked to deploy here, install locally, or update Gitinuum on this Mac from the current git-sync checkout.
---

# Deploy Here

Run the repository's local deployment script:

```bash
./scripts/deploy-here.sh /absolute/path/to/git-sync
```

The script uses `scripts/install.sh` to build and sign a release bundle, then
`scripts/install-staged.sh` to replace `/Applications/Gitinuum.app` and restart
the app and its menu helper. It verifies all four installed executables against
the built bundle. It does not contact the other Mac or atlas, or require the
Linux toolchain or SDK.

Deploy the invoking checkout as-is, including tracked or untracked changes.
Do not pull, reset, switch branches, or copy the repository. Report the deployed
revision, dirty state, and local host's result. On failure, report the failing
command and retain any installer backup; do not clear caches, install toolchains,
or change signing settings.
