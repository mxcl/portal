# Repository instructions

- Commit regularly.
- Treat `git-sync` as a continuous bidirectional Git fetch/push system. It exchanges objects and publishes ref snapshots. Each working repository remains independent.
- Each host owns its local branches, tags, stash, `HEAD`, index, and working tree. Background code may only write the peer namespaces documented in `DESIGN.md`.
- Exception: verified GitHub merge cleanup may delete an unchanged, non-checked-out local PR branch only after the configured backup destination confirms permanent retention of its complete objects and branch metadata. Never delete a default/base branch or a diverged tip.
- Preserve divergence. Never merge, rebase, reset, check out, or promote an incoming peer ref to a local ref in background code.
- Require a user action to promote a peer ref into local work if promotion is ever added.
- Use Git plumbing for object validation, pack installation, ref locking, and ref transactions. Do not replace or wrap the Git toolchain to coordinate ordinary Git commands.
- The replication contract provides per-ref atomicity and eventual consistency across a repository snapshot. Document and test any change to that contract.
- Reject incompatible protocol versions. Persistent ordering state must include a source epoch so state reset cannot make valid updates permanently stale.
- Keep one writer per state file. Add the smallest regression test for every non-trivial protocol or failure-recovery change.
