# Host discovery

Portal uses iCloud Keychain as an eventually synced host directory. The root token
keeps its existing service/account and default `ZU76A67LGU.dev.mxcl.portal` access
group. Host records use `dev.mxcl.portal.hosts.v1`, one account per host ID. Records
contain public SSH metadata and an identity fingerprint, never the token.

Create an identity explicitly on the first device only. Other devices wait for
that token to sync. Opening settings, refreshing, and connecting cannot create a
token. iCloud offers no cross-device compare-and-swap or forced immediate refresh;
creating identities on multiple devices before sync is unsupported.

A Mac publishes after **Enable This Mac**, then updates its own record on launch
and refresh. Enabling adds the token-derived public key to `authorized_keys` with
a Portal ownership comment. It does not turn on macOS Remote Login. A VPN address
can be supplied explicitly; automatic selection prefers Tailscale, then an
unambiguous private tunnel address. Native Mac Git connections retain their SSH
configuration and existing authorization.

Linux enrollment is an explicit action on a Mac. The alias must occur in
`~/.ssh/config` (including Include files). OpenSSH handles connection options and
requires an already trusted host key. Enrollment verifies the terminal protocol,
reads metadata over that authenticated connection, adds the public key, and
publishes a record owned by the enrolling Mac. Linux receives no root token and
never writes iCloud. Only that Mac can disable its enrollment. Disable requires
SSH access so revocation occurs before removing discovery. Existing authorized
keys are retained. The phone connects directly to the recorded private address;
SSH jump hosts, proxies, and Mac-only routes are not reproduced on iOS.

There is no polling or TTL. Enabled is persisted intent; availability is checked
by the phone's refresh or an actual connection. Git's active daemon connection
does not imply terminal access. Offline hosts stay registered. Git replication
configuration, ref ownership, and repository placement are unaffected.

The Mac settings list the shared directory. The phone merges discovered records
with its existing manual connections; discovered records are managed on their
owning Mac. Unknown directory versions and corrupt records fail visibly rather
than silently rewriting shared data. Records for a different token are excluded
from phone connections. A changed token requires reauthorization on each host.

Signed Mac builds require the Portal Developer ID provisioning profile, selected
by `PORTAL_DISCOVERY_PROFILE` or the installed/default profile. The installer
validates its app ID, expiry, and Keychain permission before signing. Explicit
`--enable-remote-access`, `--enroll-ssh-host ALIAS`, and `--remote-access-status`
launch arguments support deployment verification inside the signed app. Status
is written to `~/Library/Caches/dev.mxcl.portal/remote-access-status.json` and
contains no token or private key.
