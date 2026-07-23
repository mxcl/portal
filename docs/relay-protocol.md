# Relay protocol v1

The relay exposes three endpoints:

- `GET /health`
- `GET /v1/connect/{room}/{peer}` upgraded to WebSocket
- `GET|PUT /v1/catalog/{room}`

`room` and the bearer credential are separate 256-bit HMAC derivations encoded as unpadded base64url. `peer` is a random per-install identifier. WebSocket frames and catalog bodies are opaque encrypted bytes with a 1 MiB limit.

The WebSocket broadcasts binary frames to every other peer in a room. It does not interpret, persist, log, or acknowledge terminal traffic. Catalog writes replace the previous opaque blob atomically. Blobs inactive for 30 days are deleted when read; production billing cleanup may delete them sooner once the subscription grace period and retention window have elapsed.

Relay messages are additive. Mac clients may advertise `clientRole: "mac"` on
attach and send resize, clear-history, state-update, and kill messages. Terminal
events may mark replayed output with `isHistory: true`. Peers that predate these
fields continue to decode the message and ignore behavior they do not support.
After replaying history, Macs may send a `terminalSnapshot` containing the
daemon's canonical screen and grid size. Older phones ignore this additive
message; newer phones use it to render full-screen programs without taking PTY
resize authority from the Mac.

After a terminal attach, a Mac may advertise the `relay-completion-v1`
capability. A client must not send completion work until it receives that
capability for the current connection. Completion uses the attached terminal's
existing WebSocket and request ID:

- `completionRequest` contains a unique operation ID, one of
  `complete-commands`, `complete-path`, or `run-generator`, and an opaque JSON
  payload for the bundled `portal-session-bridge`.
- `completionResponse` returns the same operation ID with either an opaque JSON
  payload or an error.
- `completionCancel` identifies work that the Mac should terminate.

The Mac accepts completion only for a matching attached session, enforces
request and response limits, and invokes only those three bridge subcommands.
Command discovery is prefetched and cached per connection. Path and generator
completion each require one request/response exchange; reconnecting drops the
cache. Superseded generator requests are cancelled and late responses are
ignored.

`run-generator` has the same security implications as local Fig completion:
Fig specs and custom generators can execute shell commands as the signed-in
user. Relay encryption prevents the relay service from reading or modifying
those commands, but it does not sandbox them on the remote Mac.

Only protocol versions 1 and 2 of the local session protocol are supported. Relay envelope v1 is JSON containing an envelope version and AES-GCM combined representation. The encrypted inner message owns session identifiers, sequence numbers, message types, and payloads.
