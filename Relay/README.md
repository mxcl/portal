# Gitinuum GitHub relay

GitHub events wake Gitinuum. The Mac refreshes notifications and project counts,
then fetches changed GitHub branches. There is no recurring GitHub poll.

This is an independent, trimmed port of `~/src/canopy`: no Canopy database,
credentials, billing, hooks, iOS app, or deployment is reused.

## Configure

Create a separate PostgreSQL database and copy `.env.example` to `.env`. Set the
GitHub, OAuth, encryption and APNs credentials. Keep the database and environment
file private; the encryption key must survive deployments. PEM values accept
literal `\n` separators. Both APNs environments use the fixed topic
`dev.mxcl.git-sync.menu-helper`.

Create a GitHub App with callback `https://YOUR_RELAY_HOST/oauth/hello`, webhook
`https://YOUR_RELAY_HOST/webhook`, and a setup URL that returns the user to
`gitsync://github-connected` (or an HTTPS page linking there). Enable expiring
user tokens. Configure these read permissions: metadata, contents, issues, pull
requests, actions, checks, deployments, and Dependabot alerts.

Subscribe to pushes, branch creation/deletion, stars, issues, issue comments,
pull requests, PR reviews/comments, releases, workflow runs, check runs/suites,
deployment statuses and Dependabot alerts. Installation lifecycle events arrive
automatically. Install the App on the repositories Gitinuum tracks.

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
The included nginx example needs your hostname and TLS certificate settings.
Do not log OAuth callback query strings or authorization headers.

No production service is changed by this repository's build or tests.

## Connect a Mac

Enable [macOS Push Notifications](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment) for App ID `dev.mxcl.git-sync.menu-helper`. Create a
matching Developer ID provisioning profile and APNs credentials for its topic.
Build the app with:

```sh
GITINUUM_PUSH_PROFILE=/absolute/path/helper.provisionprofile scripts/install.sh /path/to/Gitinuum.app
```

Packaging validates the profile's identity, push entitlement and expiry, embeds
it, and signs the helper with its entitlements. Ordinary builds still work without
a profile; automatic pushes require a correctly signed helper. The profile's
APNs environment is recorded in the helper's Info.plist, never inferred from a
debug/release compiler flag.

In Gitinuum Settings → GitHub, enter the relay's HTTPS URL and connect. Return
from the browser, grant Repository Access, and Refresh. Allow Notifications for
banners; the menu remains usable when banners are disabled. Disconnect revokes
this device's relay session before removing its Keychain credential.

## Delivery contract

- API clients send `Gitinuum-Protocol: 1`. Unsupported versions are rejected.
- APNs contains only a wake-up hint. Pending fetch/count/inbox work is stored per
  device and repository. UUID replacement IDs prevent old acknowledgments from
  deleting new work; there is no resettable ordering counter.
- `/sync` registers the current repository set, revalidates user access, processes
  pending counts/inbox requests, and returns cached results plus fetch work.
  `/ack` removes only matching fetch IDs for that device after successful work.
- GitHub pagination, conditional requests and `X-Poll-Interval` are respected.
  The inbox interval is enforced across all Macs belonging to the same GitHub user.
  Rate limits leave work pending. A notification-prone webhook that arrives before
  inbox indexing gets one conditional follow-up at GitHub's interval. The helper makes at most three retries per
  trigger, then waits for a new push, launch, reconnect or explicit Refresh.
- Notification history is filtered to tracked repositories and deduplicated by
  thread/update. Initial history appears in the menu without backlog banners.
  Only the Mac posts banners; the relay never sends duplicate alert pushes.
- Stars, open issues and open PRs are separate GraphQL totals. Failed refreshes
  retain cached counts. Revoked repository access removes its results.
- Sync pause defers Git fetches. Remote-only projects can show counts, but no
  remote checkout is created or modified. Other hosts fetch for themselves.
- APNs can be delayed or dropped. Launch/reconnect/manual catch-up recovers
  missed hints; this design does not promise instant delivery while offline.

## Check

```sh
cargo test --locked
TEST_DATABASE_URL=postgres://localhost/disposable cargo test --locked -- --ignored
cd ..
swift test
python3 scripts/test-push-signing.py
```

The PostgreSQL test creates and removes its own randomly named schema. It checks
pending-work coalescing, stale acknowledgments, deduplication and cascading
repository removal. A live smoke test additionally needs a configured relay,
signed helper, and a GitHub repository: push a branch, star it, create an issue
and PR, then cause an inbox notification. Verify only the relevant paths run,
local work stays unchanged, and quiet time produces no GitHub requests.
