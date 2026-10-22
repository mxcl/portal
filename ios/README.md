# Portal for iPhone

Use your Mac’s Portal terminal sessions over SSH on Tailscale or another private
VPN. The app requires iOS 26.1 or later and has no subscription.

## Connect a Mac

1. Install Portal on the Mac and enable **System Settings → General → Sharing →
   Remote Login** for your user.
2. Connect the Mac and iPhone to the same VPN. In Portal on iPhone, open
   **Settings → Add Mac** and enter the Mac’s VPN IP, SSH username, and home path.
3. Copy `/etc/ssh/ssh_host_ed25519_key.pub` from the Mac over a trusted connection
   into the host-key field. Portal pins that key before authenticating.
4. In iPhone Settings, share the **SSH Public Key** and append it as a separate
   line to the Mac’s `~/.ssh/authorized_keys`. The `.ssh` directory should have
   mode `700`, and `authorized_keys` mode `600`.
5. Return to the session list and refresh. Open an existing session or choose
   **New Session**.

The default helper path is
`/Applications/Portal.app/Contents/Helpers/portal-session-bridge`. Connections
require an RFC 1918, Tailscale/CGNAT, or IPv6 ULA address. DNS names and public IPs
are rejected. Routing and VPN access controls belong to the VPN; the app does
not install or manage a VPN profile. Private LAN routing also works.

The app retains the existing `dev.mxcl.portal.remote` / `account-root-key-v1`
synchronizable Keychain token. HKDF derives a separate Ed25519 SSH identity from
that token; only its public key goes on the Mac. Remove that authorized key to
revoke access. Enable iCloud Keychain to share the identity across your devices.
Each Mac keeps its own SSH host key and user access controls.

## Build and verify

Open `PortalMobileApp/PortalMobileApp.xcodeproj`. The app keeps bundle identifier
`dev.mxcl.portal` and team `ZU76A67LGU` for existing TestFlight users.

From the repository root:

```sh
swift test --package-path ios
scripts/test-mobile-ssh.sh
```

The integration test requires the installed, signed Portal session helper and a
private address on `en0` (override with `PORTAL_TEST_SSH_ADDRESS`). It starts a
disposable SSH server, verifies session creation/listing/attachment, executes a
command, removes the test session, and rejects wrong host keys and tokens. It
does not modify your SSH configuration or authorized keys.

The phone uses session wire v2, already supported by the current and previous
Portal helpers. It queries supported versions on a separate SSH channel before
opening a session and rejects incompatible helpers. It does not alter Git refs,
working trees, or the replication protocol.

The independent GitHub notification relay in `Relay/` remains in use. The old
phone/session relay is excluded from this import; its atlas service
`portal-relay.service` is stopped and disabled.

To upload a new build using the signed-in Xcode account:

```sh
xcodebuild -project ios/PortalMobileApp/PortalMobileApp.xcodeproj \
  -scheme PortalMobileApp -destination 'generic/platform=iOS' \
  -archivePath /tmp/PortalMobile.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath /tmp/PortalMobile.xcarchive \
  -exportOptionsPlist ios/ExportOptions.plist \
  -exportPath /tmp/portal-mobile-export -allowProvisioningUpdates
```

## Automatic host discovery

In Portal on a Mac, open Settings → Remote Access and enable the Mac. Linux hosts
are enrolled once there using a trusted entry from `~/.ssh/config`. The iPhone's
Refresh reads the synced Keychain directory and queries registered hosts over
SSH. New records may take time to arrive through iCloud. Manual connections
remain supported. Create a shared identity only on the first device; other
devices must wait for that token to sync.
