---
name: deploy-here
description: Build, sign, install, restart, and verify Portal on the current Mac only. Use when asked to deploy here, install locally, or update Portal on this Mac from the current git-sync checkout.
---

# Deploy Here

Run the repository's local deployment script:

```bash
./scripts/deploy-here.sh /absolute/path/to/git-sync
```

The script uses `scripts/install.sh` to build and sign both release apps, then
`scripts/install-staged.sh` to replace `/Applications/Portal Hub.app` and `/Applications/Portal.app` and restart
the app and its menu helper. It verifies all five installed executables against
the built bundle. It does not contact the other Mac or atlas, or require the
Linux toolchain or SDK.

The shared installer launches the app with a minimal login environment. Keep
that boundary intact: never forward the agent's environment (including color,
pager, terminal, or `CODEX_*` overrides) to the deployed app.
Preserve the session helper and its terminal sessions during deployment. Stop
the session helper only when the user explicitly requests it separately.

Deploy the invoking checkout as-is, including tracked or untracked changes.
Do not pull, reset, switch branches, or copy the repository. Report the deployed
revision, dirty state, and local host's result. On failure, report the failing
command and retain any installer backup; do not clear caches, install toolchains,
or change signing settings.
