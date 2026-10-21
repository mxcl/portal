# Portal GitHub relay

GitHub events wake Portal. The Mac refreshes notifications and project counts,
then fetches changed GitHub branches and new tags from a matching GitHub origin. There is no recurring GitHub poll.

This is an independent, trimmed port of `~/src/canopy`: no Canopy
database contents, billing, hooks, or iOS app is reused. Credentials and hosting
are configured separately; the internal atlas trial shares APNs keys as noted below.

## Configure

Copy `.env.example` to `.env`. SQLite creates the database at `DATABASE_PATH`
(default: `gitinuum.sqlite3` in the working directory). Set the
GitHub, OAuth, encryption and APNs credentials. Keep the database and environment
file private; the encryption key must survive deployments. PEM values accept
literal `\n` separators. Both APNs environments use the fixed topic
`dev.mxcl.portal.menu-helper`.

Create a GitHub App with callback `https://YOUR_RELAY_HOST/oauth/hello`, webhook
`https://YOUR_RELAY_HOST/webhook`, and a setup URL that returns the user to
`gitsync://github-connected` (or an HTTPS page linking there). Enable expiring
user tokens. Configure these read permissions: metadata, contents, issues, pull
requests, actions, checks, deployments, and Dependabot alerts.

Subscribe to pushes, branch/tag creation/deletion, stars, issues, issue comments,
pull requests, PR reviews/comments, releases, workflow runs, check runs/suites,
deployment statuses and Dependabot alerts. Installation lifecycle events arrive
automatically. Install the App on the repositories Portal tracks.

Create a separate **OAuth App**, also with callback
`https://YOUR_RELAY_HOST/oauth/hello`. Its `notifications` authorization reads the
user's inbox; GitHub App tokens cannot do that. Connection uses both authorizations
and checks they belong to the same GitHub user. GitHub App user access limits
which repositories each device can register; installation tokens read counts.
Git fetch continues to use each Mac's existing SSH/HTTPS Git credentials.

## Run

```sh
set -a
. ./.env
set +a
cargo run --locked
```

`GET /heartbeat` returns 200. Schema creation runs on startup. Use Rust 1.94 or
newer. For production, build with `cargo build --release --locked`, install the
binary and service under a dedicated user, and configure an HTTPS reverse proxy.
The systemd service creates a private `/var/lib/gitinuum-relay` state directory.
Set `DATABASE_PATH=/var/lib/gitinuum-relay/gitinuum.sqlite3` in
`/etc/gitinuum-relay.env`; no database server is required on atlas.
The included nginx example needs your hostname and TLS certificate settings.
Do not log OAuth callback query strings or authorization headers.

SQLite uses WAL, full durability, foreign keys, and transactional schema versioning.
Run one relay process per database file; a file lock rejects a second process.
Refreshes are serialized, but network requests never hold a database transaction,
so webhooks can still record pending work. Back up a running database with
`sqlite3 /var/lib/gitinuum-relay/gitinuum.sqlite3 ".backup '/path/to/backup.sqlite3'"`;
do not copy only the main database file while it is running. Preserve the
encryption key alongside backups. Existing PostgreSQL data is not imported.

No production service is changed by this repository's build or tests.

## Internal atlas deployment

The test relay runs at **https://canopy.mxcl.dev/gitinuum**, behind Caddy, with
its own `portal-github-relay.service`, service account and SQLite database. Caddy strips
`/gitinuum` before forwarding to loopback port 3022; other Canopy routes are unchanged.
OAuth callback requests are excluded from access logging.

- GitHub App: **Gitinuum Internal** (`gitinuum-internal`), owned by `mxcl`.
- OAuth App: **Gitinuum Notifications Internal**.
- Both callbacks: `https://canopy.mxcl.dev/gitinuum/oauth/hello`.
- Webhook: `https://canopy.mxcl.dev/gitinuum/webhook`.
- Configuration: `/etc/gitinuum-relay.env` (root-only).
- Database: `/var/lib/gitinuum-relay/gitinuum.sqlite3`.

Canopy's sandbox and production APNs keys include both `dev.mxcl.canopy` and
`dev.mxcl.portal.menu-helper` for this internal trial. Revoking either shared key
would affect both apps. The helper has its own App ID and **Portal Menu Helper
Developer ID** provisioning profile. Install the GitHub App on the repositories
to track, then connect GitHub in the signed helper. The relay endpoint is built into the app.

## Connect a Mac

Enable [macOS Push Notifications](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment) for App ID `dev.mxcl.portal.menu-helper`. Create a
matching Developer ID provisioning profile and APNs credentials for its topic.
Build the app with:

```sh
PORTAL_PUSH_PROFILE=/absolute/path/helper.provisionprofile scripts/install.sh /path/to/Portal.app
```

Packaging validates the profile's identity, push entitlement and expiry, embeds
it, and signs the helper with its entitlements. Without an override, the installer
reuses the profile from `/Applications/Portal.app` when present. Set
`PORTAL_PUSH_PROFILE=` to explicitly build without push support. Builds still
work without a profile; automatic pushes require a correctly signed helper. The profile's
APNs environment is recorded in the helper's Info.plist, never inferred from a
debug/release compiler flag.

In Portal Settings → GitHub, click **Connect GitHub…**. Return
from the browser, grant Repository Access, and Refresh. Allow Notifications for
banners; the menu remains usable when banners are disabled. Disconnect revokes
this device's relay session before removing its Keychain credential.

## Delivery contract

- API clients send `Portal-Protocol: 1` (legacy `Gitinuum-Protocol` is accepted). Unsupported versions are rejected.
- APNs contains only a wake-up hint. Pending fetch/count/inbox work is stored per
  device and repository. UUID replacement IDs prevent old acknowledgments from
  deleting new work; there is no resettable ordering counter.
- `/sync` registers the current repository set, revalidates user access, processes
  pending counts/inbox requests, and returns cached results plus fetch work.
  `/ack` removes only matching fetch IDs for that device after successful work.
- GitHub pagination and `X-Poll-Interval` are respected. The optional sync
  `refreshInbox` flag queues only inbox reconciliation and invalidates its
  conditional timestamp to detect read-state changes. Clients check every minute
  while unread, and after notification clicks; all checks share the per-user throttle.
  The inbox interval is enforced across all Macs belonging to the same GitHub user.
  Rate limits leave work pending. A notification-prone webhook that arrives before
  inbox indexing gets one conditional follow-up at GitHub's interval. The helper makes at most three retries per
  trigger, then waits for a new trigger (including the unread timer or a notification click).
- Notification history is filtered to tracked repositories and deduplicated by
  thread/update. Initial history appears in the menu without backlog banners.
  Only the Mac posts banners; the relay never sends duplicate alert pushes.
- The menu bar's blue dot reflects unread GitHub notifications for tracked
  repositories, independently of the history limit. Read status is reconciled
  after a complete inbox refresh; failures and 304 responses preserve it.
  Explicit catch-up bypasses the conditional cache while respecting GitHub's
  poll interval. Opening the menu does not mark notifications read.
- Stars, open issues and open PRs are separate GraphQL totals. Failed refreshes
  retain cached counts. Revoked repository access removes its results.
- Sync pause defers Git fetches. Remote-only projects can show counts, but no
  remote checkout is created or modified. Other hosts fetch for themselves.
- APNs can be delayed or dropped. Launch/reconnect/manual catch-up recovers
  missed hints; this design does not promise instant delivery while offline.

## Check

```sh
cargo test --locked
cd ..
swift test
python3 scripts/test-push-signing.py
```

SQLite tests use temporary files with no external services. They check restart
durability, process locking, pending-work coalescing, stale acknowledgments,
bounded retries, deduplication, JSON/credential storage, foreign keys and schema
version rejection. A live smoke test additionally needs a configured relay,
signed helper, and a GitHub repository: push a branch, star it, create an issue
and PR, then cause an inbox notification. Verify only the relevant paths run,
local work stays unchanged, and quiet time produces no GitHub requests.

## Atlas service naming and incident rebuild

The GitHub relay uses `portal-github-relay.service` and
`/usr/local/bin/portal-github-relay`. This avoids colliding with the independent
`portal-relay.service` encrypted session relay. The old `gitinuum-relay.service`
name remains a systemd alias. Retain the existing service account, state directory,
root-only environment file, database path, public `/gitinuum` routes, OAuth
callbacks and protocol compatibility fields; changing the service name does not
require migrating these. Do not run both unit names as separate processes.

The October 2026 incident rebuild updates rustls-webpki to 0.103.16 and
webpki-root-certs to 1.0.10 without changing application code or database schema.
Build on the development machine with `cargo zigbuild --release --locked --target
aarch64-unknown-linux-gnu`; preserve the existing executable and unit for rollback,
then verify `/heartbeat` on loopback port 3022 after a controlled restart.
