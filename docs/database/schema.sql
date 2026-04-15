-- PostgreSQL DDL for Distributed Real-Time Configuration Delivery Platform
-- Rewritten from scratch according to updated requirements.md

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1) Environment dictionary
CREATE TABLE IF NOT EXISTS environments (
    id SMALLINT PRIMARY KEY,
    code TEXT NOT NULL UNIQUE CHECK (code IN ('dev', 'stage', 'prod')),
    name TEXT NOT NULL
);

INSERT INTO environments (id, code, name)
VALUES
    (1, 'dev', 'Development'),
    (2, 'stage', 'Staging'),
    (3, 'prod', 'Production')
ON CONFLICT (id) DO NOTHING;

-- 2) Services
CREATE TABLE IF NOT EXISTS services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_key TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL UNIQUE,
    namespace TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3) Configs
CREATE TABLE IF NOT EXISTS configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL REFERENCES services(id),
    environment_id SMALLINT NOT NULL REFERENCES environments(id),
    config_key TEXT NOT NULL,
    is_secret BOOLEAN NOT NULL DEFAULT false,
    format TEXT NOT NULL CHECK (format IN ('kv', 'json')),
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deleted')),
    current_version BIGINT NOT NULL DEFAULT 0 CHECK (current_version >= 0),
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ,
    CONSTRAINT uq_configs_service_env_key UNIQUE (service_id, environment_id, config_key)
);

CREATE INDEX IF NOT EXISTS idx_configs_service_env ON configs(service_id, environment_id);
CREATE INDEX IF NOT EXISTS idx_configs_env ON configs(environment_id);

-- 4) Immutable version history
CREATE TABLE IF NOT EXISTS config_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    version BIGINT NOT NULL CHECK (version > 0),
    payload JSONB NOT NULL,
    payload_hash TEXT NOT NULL,
    is_secret BOOLEAN NOT NULL DEFAULT false,
    encrypted_payload BYTEA,
    encryption_key_ref TEXT,
    change_type TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'rollback', 'delete')),
    change_reason TEXT,
    created_by TEXT NOT NULL,
    source_ip INET,
    correlation_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_config_versions_config_version UNIQUE (config_id, version),
    CONSTRAINT chk_secret_payload_consistency CHECK (
        (is_secret = false)
        OR
        (is_secret = true AND encrypted_payload IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_config_versions_config_ver_desc
    ON config_versions(config_id, version DESC);
CREATE INDEX IF NOT EXISTS idx_config_versions_created_at
    ON config_versions(created_at DESC);

-- 5) Rollout state
CREATE TABLE IF NOT EXISTS rollouts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    baseline_version BIGINT NOT NULL CHECK (baseline_version > 0),
    target_version BIGINT NOT NULL CHECK (target_version > 0),
    strategy TEXT NOT NULL CHECK (strategy IN ('instant', 'gradual', 'canary')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'paused', 'stopped', 'rolled_back', 'completed', 'failed')),
    criteria JSONB,
    percentage SMALLINT,
    rollback_to_version BIGINT,
    started_by TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    stopped_at TIMESTAMPTZ,
    CONSTRAINT chk_rollout_percentage CHECK (percentage IS NULL OR (percentage >= 0 AND percentage <= 100))
);

CREATE INDEX IF NOT EXISTS idx_rollouts_config_started_at
    ON rollouts(config_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_rollouts_status
    ON rollouts(status);

-- 6) Delivery outbox with retry/dead support
CREATE TABLE IF NOT EXISTS delivery_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    version BIGINT NOT NULL CHECK (version > 0),
    channel TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('config.updated', 'config.rollback', 'config.deleted')),
    payload JSONB NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'publishing', 'published', 'failed', 'dead')),
    attempt_count INT NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at TIMESTAMPTZ,
    last_attempt_at TIMESTAMPTZ,
    last_error TEXT,
    last_error_code TEXT,
    last_error_http_status INT,
    published_at TIMESTAMPTZ,
    dead_at TIMESTAMPTZ,
    dead_reason TEXT,
    redrive_count INT NOT NULL DEFAULT 0 CHECK (redrive_count >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_delivery_outbox_cfg_ver_event UNIQUE (config_id, version, event_type),
    CONSTRAINT chk_dead_fields CHECK (
        (status <> 'dead')
        OR
        (status = 'dead' AND dead_at IS NOT NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_delivery_outbox_status_next_attempt
    ON delivery_outbox(status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_delivery_outbox_created_at
    ON delivery_outbox(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_delivery_outbox_dead
    ON delivery_outbox(dead_at)
    WHERE status = 'dead';

-- 7) Re-drive history for dead events
CREATE TABLE IF NOT EXISTS delivery_redrive_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    outbox_id UUID NOT NULL REFERENCES delivery_outbox(id) ON DELETE CASCADE,
    trigger_type TEXT NOT NULL CHECK (trigger_type IN ('manual', 'scheduled')),
    triggered_by TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ,
    result TEXT NOT NULL CHECK (result IN ('success', 'failed', 'skipped')),
    attempts_before INT NOT NULL CHECK (attempts_before >= 0),
    attempts_after INT CHECK (attempts_after IS NULL OR attempts_after >= 0),
    note TEXT
);

CREATE INDEX IF NOT EXISTS idx_delivery_redrive_log_outbox_started_at
    ON delivery_redrive_log(outbox_id, started_at DESC);

-- 8) Client apply feedback (ACK/NACK) without persistent agent registry
CREATE TABLE IF NOT EXISTS client_apply_feedback (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL REFERENCES services(id),
    environment_id SMALLINT NOT NULL REFERENCES environments(id),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    version BIGINT NOT NULL CHECK (version > 0),
    status TEXT NOT NULL CHECK (status IN ('applied', 'rejected')),
    error_message TEXT,
    source_ip INET,
    correlation_id TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_client_apply_feedback_cfg_ver_time
    ON client_apply_feedback(config_id, version, received_at DESC);
CREATE INDEX IF NOT EXISTS idx_client_apply_feedback_service_env_time
    ON client_apply_feedback(service_id, environment_id, received_at DESC);

-- 9) Audit log
CREATE TABLE IF NOT EXISTS audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    operation TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id UUID,
    service_id UUID REFERENCES services(id),
    config_id UUID REFERENCES configs(id),
    version BIGINT,
    actor_id TEXT NOT NULL,
    actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'service')),
    source_ip INET,
    correlation_id TEXT,
    diff JSONB,
    meta JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_audit_log_service_created_at
    ON audit_log(service_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_actor_created_at
    ON audit_log(actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at
    ON audit_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_config_created_at
    ON audit_log(config_id, created_at DESC);

-- Notes:
-- - Reconciliation is stateless; no client_agents/agent_config_state tables.
-- - Channel naming policy (service:{service_key}:{environment}) is formed in application logic.
