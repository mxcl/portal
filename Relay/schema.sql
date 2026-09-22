CREATE TABLE IF NOT EXISTS devices (
    id BLOB PRIMARY KEY NOT NULL,
    user_id INTEGER,
    token text,
    environment text NOT NULL DEFAULT 'production',
    app_credentials BLOB, app_nonce BLOB,
    inbox_credentials BLOB, inbox_nonce BLOB,
    last_modified text,
    initialized INTEGER NOT NULL DEFAULT 0 CHECK (initialized IN (0,1)),
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS oauth_states (
    id BLOB PRIMARY KEY NOT NULL,
    device BLOB NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    kind text NOT NULL,
    expires_at INTEGER NOT NULL DEFAULT (unixepoch() + 600)
);
CREATE TABLE IF NOT EXISTS tracked (
    device BLOB NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    repository text NOT NULL,
    repository_id INTEGER NOT NULL,
    installation_id INTEGER NOT NULL,
    counts TEXT,
    PRIMARY KEY(device,repository)
);
CREATE TABLE IF NOT EXISTS pending (
    device BLOB NOT NULL,
    repository text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('fetch','counts','notifications')),
    id BLOB NOT NULL UNIQUE,
    attempts integer NOT NULL DEFAULT 0,
    PRIMARY KEY(device,repository,kind),
    FOREIGN KEY(device,repository) REFERENCES tracked(device,repository) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS deliveries (
    id text PRIMARY KEY,
    created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE TABLE IF NOT EXISTS notifications (
    device BLOB NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    id text NOT NULL,
    repository text NOT NULL,
    updated_at INTEGER NOT NULL,
    note TEXT NOT NULL,
    PRIMARY KEY(device,id)
);
-- GitHub's inbox polling limit belongs to the user, even when multiple Macs wake together.
CREATE TABLE IF NOT EXISTS inbox_limits (
    user_id INTEGER PRIMARY KEY,
    next_poll_at INTEGER
);
CREATE INDEX IF NOT EXISTS notifications_recent ON notifications(device,updated_at DESC);
