-- PostgreSQL DDL for Distributed Real-Time Configuration Delivery Platform
-- Scope: requirements.md (backend + agent contracts)

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Environment dictionary
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

-- 2. Services
CREATE TABLE IF NOT EXISTS services (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    namespace TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Configs
CREATE TABLE IF NOT EXISTS configs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id UUID NOT NULL REFERENCES services(id),
    environment_id SMALLINT NOT NULL REFERENCES environments(id),
    config_key TEXT NOT NULL,
    config_type TEXT NOT NULL CHECK (config_type IN ('config', 'secret')),
    format TEXT NOT NULL CHECK (format IN ('kv', 'json', 'yaml')),
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

-- 4. Immutable version history
CREATE TABLE IF NOT EXISTS config_versions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    version BIGINT NOT NULL CHECK (version > 0),
    payload JSONB NOT NULL,
    payload_hash TEXT NOT NULL,
    is_secret BOOLEAN NOT NULL DEFAULT false,
    encrypted_payload BYTEA,
    encryption_key_ref TEXT,
    change_reason TEXT,
    change_type TEXT NOT NULL CHECK (change_type IN ('create', 'update', 'rollback', 'delete')),
    created_by TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_ip INET,
    CONSTRAINT uq_config_versions_config_version UNIQUE (config_id, version),
    CONSTRAINT chk_secret_payload_consistency CHECK (
        (is_secret = true AND encrypted_payload IS NOT NULL)
        OR
        (is_secret = false)
    )
);

CREATE INDEX IF NOT EXISTS idx_config_versions_config_ver_desc ON config_versions(config_id, version DESC);
CREATE INDEX IF NOT EXISTS idx_config_versions_created_at ON config_versions(created_at DESC);

-- 5. Rollout state
CREATE TABLE IF NOT EXISTS rollouts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    target_version BIGINT NOT NULL CHECK (target_version > 0),
    strategy TEXT NOT NULL CHECK (strategy IN ('instant', 'gradual', 'canary')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'paused', 'stopped', 'rolled_back', 'completed', 'failed')),
    criteria JSONB,
    percentage SMALLINT,
    started_by TEXT NOT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    stopped_at TIMESTAMPTZ,
    rollback_to_version BIGINT,
    CONSTRAINT chk_rollout_percentage CHECK (percentage IS NULL OR (percentage >= 0 AND percentage <= 100))
);

CREATE INDEX IF NOT EXISTS idx_rollouts_config_started_at ON rollouts(config_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_rollouts_status ON rollouts(status);

-- 6. Transactional outbox for delivery publisher
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
    last_error TEXT,
    published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_delivery_outbox_cfg_ver_event UNIQUE (config_id, version, event_type)
);

CREATE INDEX IF NOT EXISTS idx_delivery_outbox_status_next_attempt
    ON delivery_outbox(status, next_attempt_at);
CREATE INDEX IF NOT EXISTS idx_delivery_outbox_created_at
    ON delivery_outbox(created_at DESC);

-- 7. Client agents
CREATE TABLE IF NOT EXISTS client_agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_uid TEXT NOT NULL UNIQUE,
    service_id UUID NOT NULL REFERENCES services(id),
    environment_id SMALLINT NOT NULL REFERENCES environments(id),
    metadata JSONB,
    last_seen_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_client_agents_service_env
    ON client_agents(service_id, environment_id);

-- 8. Agent applied-state for reconciliation and lag detection
CREATE TABLE IF NOT EXISTS agent_config_state (
    agent_id UUID NOT NULL REFERENCES client_agents(id) ON DELETE CASCADE,
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    applied_version BIGINT NOT NULL CHECK (applied_version >= 0),
    apply_status TEXT NOT NULL CHECK (apply_status IN ('applied', 'rejected', 'pending')),
    last_error TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_id, config_id)
);

CREATE INDEX IF NOT EXISTS idx_agent_config_state_config_applied
    ON agent_config_state(config_id, applied_version);

-- 9. Delivery receipts (internal ACK/ERROR tracking)
CREATE TABLE IF NOT EXISTS delivery_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    config_id UUID NOT NULL REFERENCES configs(id) ON DELETE CASCADE,
    version BIGINT NOT NULL CHECK (version > 0),
    agent_id UUID NOT NULL REFERENCES client_agents(id) ON DELETE CASCADE,
    receipt_status TEXT NOT NULL CHECK (receipt_status IN ('applied', 'rejected')),
    error_message TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_delivery_receipt_cfg_ver_agent UNIQUE (config_id, version, agent_id)
);

CREATE INDEX IF NOT EXISTS idx_delivery_receipts_config_ver
    ON delivery_receipts(config_id, version);
CREATE INDEX IF NOT EXISTS idx_delivery_receipts_agent
    ON delivery_receipts(agent_id, received_at DESC);

-- 10. Audit log
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

-- Optional: retention helpers (policy execution remains external, e.g. pg_cron)
-- Example target: keep >= 1 year versions/audit as per requirements.
