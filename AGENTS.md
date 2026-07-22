# Repository instructions

- Commit regularly.

## Protocol compatibility

Vaultty has four independently deployed protocol seams: the app-to-session-daemon wire protocol, relay messages and catalogs, the encrypted relay envelope, and SSH helpers. A release must tolerate one adjacent release of version skew at each seam.

- Do not promise permanent compatibility. Support the current and immediately previous released protocol where version skew can occur.
- Keep the session wire protocol usable in both upgrade directions: the current client with the previous daemon and the previous client with the current daemon. Before incrementing its version, add negotiation or fallback and test both pairings.
- Roll out breaking wire changes in two releases. First ship readers that accept both representations. Start writing the new representation only after that compatibility release exists.
- Prefer additive relay-message and catalog changes. Add optional fields, preserve defaults for missing fields, and keep unknown message kinds decodable. Use capabilities before sending behavior an older peer cannot understand.
- Keep encrypted-envelope readers for every envelope version that supported peers or persisted catalogs may still contain. Do not change the write version until peers advertise read support for it.
- Treat the running session daemon as independently deployed from the helper on disk. A daemon inside the supported adjacent-version window is compatible, not stale merely because a newer helper exists. Replace an empty stale daemon only through an atomic daemon-side operation; otherwise require explicit consent. Never use a check-then-kill sequence that can race session creation.
- SSH enrollment must verify session protocol compatibility, not only helper presence or unrelated capabilities.
- Add compatibility fixtures for every supported wire version. Tests must cover current client/current daemon, current client/previous daemon, previous client/current daemon, and current/previous iPhone-to-Mac relay pairings when those versions differ.
- `scripts/validate-protocol-compatibility.sh` is the executable release gate. Update it and its fixtures with every intentional protocol migration. Do not bypass or weaken the gate to publish.
