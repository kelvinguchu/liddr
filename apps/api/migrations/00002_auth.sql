-- +goose Up
CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    phone text NOT NULL UNIQUE CHECK (phone ~ '^254[17][0-9]{8}$'),
    account_status text NOT NULL DEFAULT 'active'
        CHECK (account_status IN ('active', 'restricted', 'suspended', 'banned', 'deactivated')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- One row per user and role, kept after revocation, so that signing in again
-- can never restore a role that operations took away.
CREATE TABLE user_roles (
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role text NOT NULL CHECK (role IN ('rider', 'driver', 'ops', 'admin')),
    granted_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    PRIMARY KEY (user_id, role)
);

-- phone is sensitive. ip_hash is keyed, so raw addresses are not retained here.
-- Rows can be deleted seven days after created_at.
CREATE TABLE auth_challenges (
    id uuid PRIMARY KEY,
    phone text NOT NULL,
    requested_role text NOT NULL CHECK (requested_role IN ('rider', 'driver')),
    code_hash bytea NOT NULL,
    ip_hash bytea NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    expires_at timestamptz NOT NULL,
    closed_at timestamptz,
    delivery_failed_at timestamptz,
    created_at timestamptz NOT NULL
);

CREATE INDEX auth_challenges_phone_created ON auth_challenges (phone, created_at DESC);
CREATE INDEX auth_challenges_ip_created ON auth_challenges (ip_hash, created_at DESC);

-- One row per refresh generation. family_id identifies a device sign-in.
CREATE TABLE auth_sessions (
    id uuid PRIMARY KEY,
    family_id uuid NOT NULL,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    access_token_hash bytea NOT NULL UNIQUE,
    refresh_token_hash bytea NOT NULL UNIQUE,
    access_expires_at timestamptz NOT NULL,
    refresh_expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoked_reason text CHECK (
        revoked_reason IN ('rotated', 'superseded', 'logout', 'reuse_detected', 'account_blocked')
    ),
    replaced_by_id uuid REFERENCES auth_sessions (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL,
    CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL))
);

CREATE INDEX auth_sessions_family ON auth_sessions (family_id);
CREATE INDEX auth_sessions_user ON auth_sessions (user_id);

-- ip is sensitive. Rows can be deleted 90 days after created_at.
CREATE TABLE audit_events (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action text NOT NULL,
    user_id uuid REFERENCES users (id) ON DELETE SET NULL,
    family_id uuid,
    request_id text NOT NULL,
    ip inet NOT NULL,
    created_at timestamptz NOT NULL
);

CREATE INDEX audit_events_user_created ON audit_events (user_id, created_at DESC);
