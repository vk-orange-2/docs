# Логическая схема БД (ER)

## Назначение
Схема отражает актуальные требования `requirements.md`:
- управление конфигурациями (`kv`, `json`) и секретами через признак `is_secret`;
- версионирование и глобальный rollback;
- rollout-стратегии с явным `baseline_version`;
- асинхронная доставка через transactional outbox;
- retry/dead/re-drive для публикации;
- stateless reconciliation (без постоянного реестра агентов).

## Сущности и атрибуты

### 1) `services`
- `id` (UUID, PK) — уникальный идентификатор сервиса.
- `service_key` (TEXT, UNIQUE, NOT NULL) — стабильный ключ сервиса для каналов доставки.
- `name` (TEXT, UNIQUE, NOT NULL) — отображаемое имя сервиса.
- `namespace` (TEXT, NOT NULL) — логическая область изоляции/шардинга.
- `description` (TEXT, NULL) — описание сервиса.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время создания.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время изменения.

Назначение: справочник сервисов и источник `service_key` для channel naming.

### 2) `environments`
- `id` (SMALLINT, PK) — технический идентификатор окружения.
- `code` (TEXT, UNIQUE, NOT NULL) — код окружения (`dev`, `stage`, `prod`).
- `name` (TEXT, NOT NULL) — отображаемое имя.

Назначение: фиксированный справочник окружений.

### 3) `configs`
- `id` (UUID, PK) — идентификатор логической конфигурации.
- `service_id` (UUID, FK -> `services.id`, NOT NULL) — владелец конфигурации.
- `environment_id` (SMALLINT, FK -> `environments.id`, NOT NULL) — окружение.
- `config_key` (TEXT, NOT NULL) — ключ конфигурации в рамках `service+environment`.
- `is_secret` (BOOLEAN, NOT NULL, default `false`) — признак секретности.
- `format` (TEXT, NOT NULL) — формат payload: `kv|json`.
- `status` (TEXT, NOT NULL) — `active|deleted` (soft delete).
- `current_version` (BIGINT, NOT NULL, default `0`) — текущая актуальная версия.
- `created_by` (TEXT, NOT NULL) — инициатор создания.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время создания.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время последнего изменения.
- `deleted_at` (TIMESTAMPTZ, NULL) — время soft delete.

Назначение: агрегат верхнего уровня конфигурации.

Уникальность:
- `(service_id, environment_id, config_key)` — единственная конфигурация на ключ в контексте сервиса/окружения.

### 4) `config_versions`
- `id` (UUID, PK) — идентификатор версии.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — ссылка на конфигурацию.
- `version` (BIGINT, NOT NULL) — номер версии (монотонно растет в рамках `config_id`).
- `payload` (JSONB, NOT NULL) — нормализованное тело конфигурации.
- `payload_hash` (TEXT, NOT NULL) — хеш payload для diff/идемпотентности.
- `is_secret` (BOOLEAN, NOT NULL) — признак секретности в историческом срезе.
- `encrypted_payload` (BYTEA, NULL) — шифротекст (обязателен для секрета).
- `encryption_key_ref` (TEXT, NULL) — ссылка на ключ шифрования.
- `change_type` (TEXT, NOT NULL) — `create|update|rollback|delete`.
- `change_reason` (TEXT, NULL) — причина изменения.
- `created_by` (TEXT, NOT NULL) — инициатор.
- `source_ip` (INET, NULL) — источник запроса.
- `correlation_id` (TEXT, NULL) — трассировка операции.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время фиксации версии.

Назначение: immutable-история версий, включая rollback как новую версию.

Уникальность:
- `(config_id, version)` — уникальность версии в рамках конфигурации.

### 5) `rollouts`
- `id` (UUID, PK) — идентификатор rollout.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — конфигурация rollout.
- `baseline_version` (BIGINT, NOT NULL) — версия до старта rollout.
- `target_version` (BIGINT, NOT NULL) — версия, распространяемая rollout.
- `strategy` (TEXT, NOT NULL) — `instant|gradual|canary`.
- `status` (TEXT, NOT NULL) — `pending|running|paused|stopped|rolled_back|completed|failed`.
- `criteria` (JSONB, NULL) — критерии отбора клиентов (canary/gradual).
- `percentage` (SMALLINT, NULL) — доля клиентов для gradual (0..100).
- `rollback_to_version` (BIGINT, NULL) — версия, на которую выполнен rollback rollout.
- `started_by` (TEXT, NOT NULL) — инициатор запуска.
- `started_at` (TIMESTAMPTZ, NOT NULL) — время старта.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время изменения статуса.
- `stopped_at` (TIMESTAMPTZ, NULL) — время остановки/завершения.

Назначение: жизненный цикл rollout и фиксация baseline для корректного rollback rollout.

### 6) `delivery_outbox`
- `id` (UUID, PK) — идентификатор outbox-события.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — конфигурация события.
- `version` (BIGINT, NOT NULL) — версия для публикации.
- `channel` (TEXT, NOT NULL) — канал вида `service:{service_key}:{environment}`.
- `event_type` (TEXT, NOT NULL) — `config.updated|config.rollback|config.deleted`.
- `payload` (JSONB, NOT NULL) — полезная нагрузка события.
- `status` (TEXT, NOT NULL) — `pending|publishing|published|failed|dead`.
- `attempt_count` (INT, NOT NULL, default `0`) — число попыток публикации.
- `next_attempt_at` (TIMESTAMPTZ, NULL) — момент следующей попытки.
- `last_attempt_at` (TIMESTAMPTZ, NULL) — момент последней попытки.
- `last_error` (TEXT, NULL) — последнее сообщение об ошибке.
- `last_error_code` (TEXT, NULL) — классификатор ошибки.
- `last_error_http_status` (INT, NULL) — HTTP статус ошибки (если применимо).
- `published_at` (TIMESTAMPTZ, NULL) — успешная публикация.
- `dead_at` (TIMESTAMPTZ, NULL) — время перехода в `dead`.
- `dead_reason` (TEXT, NULL) — причина перехода в `dead`.
- `redrive_count` (INT, NOT NULL, default `0`) — число циклов re-drive.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время создания.

Назначение: transactional outbox + хранение retry/dead состояния.

Уникальность:
- `(config_id, version, event_type)` — идемпотентность публикации.

### 7) `delivery_redrive_log`
- `id` (UUID, PK) — идентификатор записи re-drive.
- `outbox_id` (UUID, FK -> `delivery_outbox.id`, NOT NULL) — ссылка на outbox-событие.
- `trigger_type` (TEXT, NOT NULL) — `manual|scheduled`.
- `triggered_by` (TEXT, NULL) — инициатор (для manual).
- `started_at` (TIMESTAMPTZ, NOT NULL) — начало re-drive.
- `finished_at` (TIMESTAMPTZ, NULL) — окончание.
- `result` (TEXT, NOT NULL) — `success|failed|skipped`.
- `attempts_before` (INT, NOT NULL) — количество попыток до re-drive.
- `attempts_after` (INT, NULL) — количество попыток после re-drive.
- `note` (TEXT, NULL) — комментарий/диагностика.

Назначение: аудит и диагностика повторной обработки dead-событий.

### 8) `client_apply_feedback`
- `id` (UUID, PK) — идентификатор обратной связи.
- `service_id` (UUID, FK -> `services.id`, NOT NULL) — сервисный контекст.
- `environment_id` (SMALLINT, FK -> `environments.id`, NOT NULL) — окружение.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — конфигурация.
- `version` (BIGINT, NOT NULL) — версия.
- `status` (TEXT, NOT NULL) — `applied|rejected`.
- `error_message` (TEXT, NULL) — причина ошибки при `rejected`.
- `source_ip` (INET, NULL) — источник.
- `correlation_id` (TEXT, NULL) — id трассировки/idempotency от клиента.
- `received_at` (TIMESTAMPTZ, NOT NULL) — время получения.

Назначение: хранение ACK/NACK без постоянного идентификатора агента.

### 9) `audit_log`
- `id` (UUID, PK) — идентификатор записи аудита.
- `operation` (TEXT, NOT NULL) — тип операции.
- `entity_type` (TEXT, NOT NULL) — сущность операции.
- `entity_id` (UUID, NULL) — id сущности (если применимо).
- `service_id` (UUID, NULL, FK -> `services.id`) — сервисный контекст.
- `config_id` (UUID, NULL, FK -> `configs.id`) — конфигурация.
- `version` (BIGINT, NULL) — версия, если применимо.
- `actor_id` (TEXT, NOT NULL) — инициатор.
- `actor_type` (TEXT, NOT NULL) — `user|service`.
- `source_ip` (INET, NULL) — источник запроса.
- `correlation_id` (TEXT, NULL) — трассировка.
- `diff` (JSONB, NULL) — diff изменений.
- `meta` (JSONB, NULL) — расширенные атрибуты.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время записи.

Назначение: единый неизменяемый аудит.

## Связи и кардинальности
- `services (1) -> (N) configs`
- `environments (1) -> (N) configs`
- `configs (1) -> (N) config_versions`
- `configs (1) -> (N) rollouts`
- `configs (1) -> (N) delivery_outbox`
- `delivery_outbox (1) -> (N) delivery_redrive_log`
- `services (1) -> (N) client_apply_feedback`
- `configs (1) -> (N) client_apply_feedback`
- `services/configs (1) -> (N) audit_log`

## Ключевые ограничения
- `config_versions(config_id, version)` — версия уникальна в рамках конфигурации.
- Для секрета `encrypted_payload` обязателен.
- `configs.format` ограничен `kv|json`.
- `rollouts.percentage` в диапазоне `0..100`.
- `rollouts.baseline_version > 0`, `target_version > 0`.
- `delivery_outbox.status=dead` требует заполнения `dead_at`.

## Индексация (минимальный набор)
- `configs(service_id, environment_id)`
- `configs(environment_id)`
- `config_versions(config_id, version DESC)`
- `rollouts(config_id, started_at DESC)`
- `rollouts(status)`
- `delivery_outbox(status, next_attempt_at)`
- `delivery_outbox(dead_at)` partial index where `status='dead'`
- `client_apply_feedback(config_id, version, received_at DESC)`
- `audit_log(service_id, created_at DESC)`
- `audit_log(actor_id, created_at DESC)`
- `audit_log(created_at DESC)`

## Явные допущения
- Reconciliation реализован stateless и не требует постоянного реестра агентов.
- `client_apply_feedback` хранит ACK/NACK без постоянного идентификатора агента.
- Канал доставки формируется на уровне приложения из `service_key` и `environment.code`.
- Политики rate limit реализуются на API Gateway/Ingress и не требуют отдельной таблицы в PostgreSQL.
