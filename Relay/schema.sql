CREATE TABLE IF NOT EXISTS devices (
    id uuid PRIMARY KEY,
    user_id bigint,
    token text,
    environment text NOT NULL DEFAULT 'production',
    app_credentials bytea, app_nonce bytea,
    inbox_credentials bytea, inbox_nonce bytea,
    last_modified text,
    initialized boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS oauth_states (
    id uuid PRIMARY KEY,
    device uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    kind text NOT NULL,
    expires_at timestamptz NOT NULL DEFAULT now() + interval '10 minutes'
);
CREATE TABLE IF NOT EXISTS tracked (
    device uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    repository text NOT NULL,
    repository_id bigint NOT NULL,
    installation_id bigint NOT NULL,
    counts jsonb,
    PRIMARY KEY(device,repository)
);
CREATE TABLE IF NOT EXISTS pending (
    device uuid NOT NULL,
    repository text NOT NULL,
    kind text NOT NULL CHECK (kind IN ('fetch','counts','notifications')),
    id uuid NOT NULL UNIQUE,
    attempts integer NOT NULL DEFAULT 0,
    PRIMARY KEY(device,repository,kind),
    FOREIGN KEY(device,repository) REFERENCES tracked(device,repository) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS deliveries (
    id text PRIMARY KEY,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS notifications (
    device uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    id text NOT NULL,
    repository text NOT NULL,
    updated_at timestamptz NOT NULL,
    note jsonb NOT NULL,
    PRIMARY KEY(device,id)
);
-- GitHub's inbox polling limit belongs to the user, even when multiple Macs wake together.
CREATE TABLE IF NOT EXISTS inbox_limits (
    user_id bigint PRIMARY KEY,
    next_poll_at timestamptz
);
CREATE INDEX IF NOT EXISTS notifications_recent ON notifications(device,updated_at DESC);
