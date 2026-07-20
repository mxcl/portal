# Relay protocol v1

The relay exposes three endpoints:

- `GET /health`
- `GET /v1/connect/{room}/{peer}` upgraded to WebSocket
- `GET|PUT /v1/catalog/{room}`

`room` and the bearer credential are separate 256-bit HMAC derivations encoded as unpadded base64url. `peer` is a random per-install identifier. WebSocket frames and catalog bodies are opaque encrypted bytes with a 1 MiB limit.

The WebSocket broadcasts binary frames to every other peer in a room. It does not interpret, persist, log, or acknowledge terminal traffic. Catalog writes replace the previous opaque blob atomically. Blobs inactive for 30 days are deleted when read; production billing cleanup may delete them sooner once the subscription grace period and retention window have elapsed.

Only protocol versions 1 and 2 of the local session protocol are supported. Relay envelope v1 is JSON containing an envelope version and AES-GCM combined representation. The encrypted inner message owns session identifiers, sequence numbers, message types, and payloads.

