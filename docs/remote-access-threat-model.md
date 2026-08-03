# Portal remote access threat model

Remote access extends a live terminal from a Mac to Apple devices signed into the same iCloud Keychain account. The relay is a delivery service, not a trusted terminal endpoint.

## Security boundary

- A 256-bit account root key is generated on-device and stored as a synchronizable iCloud Keychain item.
- Independent keys and opaque identifiers are derived for relay routing, relay authorization, terminal traffic, and the session catalog.
- Terminal messages and catalog snapshots use AES-256-GCM with purpose-bound authenticated data.
- The Mac initiates its relay connection. The relay never opens an inbound port or connection to the Mac.
- The relay stores only an encrypted catalog blob. Live terminal ciphertext is broadcast in memory and discarded.
- The daemon accepts resize authority from Mac-role clients only. Phone-role clients can send input but cannot change PTY geometry.

## Compromised relay

A compromised relay can observe timing, message size, the number of peers in an opaque room, and an opaque room identifier. It can delay, drop, duplicate, reorder, or replay ciphertext and can deny service. It cannot decrypt terminal contents or produce a new authenticated terminal command without the account root key.

Sequence numbers live inside encrypted protocol messages. Clients must reject duplicate or stale sequences and request a fresh canonical snapshot after a gap.

## Compromised Apple account or unlocked device

Remote access deliberately grants devices with access to the synchronizable iCloud Keychain root key the ability to control enabled Macs. Apple-account recovery and device security are therefore part of the trust boundary. The MVP mitigation for a lost phone is to end the relevant sessions on a Mac. Per-device revocation and a global kill switch are deferred.

## Subscription boundary

Billing authorizes attach operations but is not a cryptographic trust root. A billing outage must not cause key rotation or destroy sessions. Catalog ciphertext is eligible for deletion 30 days after true subscription expiration.

## Explicit MVP limitations

- Traffic analysis and denial of service by the relay are not prevented.
- A malicious relay can replay valid ciphertext; clients are responsible for sequence validation.
- No device revocation or emergency account-wide kill switch is included.
- Full terminal accessibility is deferred.
- Self-hosted relays are not supported, although the relay implementation is open source.

