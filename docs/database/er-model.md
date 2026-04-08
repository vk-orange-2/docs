# Логическая схема БД (ER)

## Назначение
Схема покрывает управление конфигурациями и секретами, версионирование, rollout, аудит и publish-пайплайн через outbox в соответствии с `requirements.md`.

## Сущности и атрибуты

### 1) `services`
- `id` (UUID, PK) — уникальный идентификатор сервиса.
- `name` (TEXT, UNIQUE, NOT NULL) — уникальное имя сервиса.
- `namespace` (TEXT, NOT NULL) — логическое пространство сервиса (используется в изоляции/шардинге).
- `description` (TEXT, NULL) — человекочитаемое описание сервиса.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время создания записи.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время последнего изменения записи.

Назначение: каталог сервисов для привязки конфигураций и поиска по service.

### 2) `environments`
- `id` (SMALLINT, PK) — технический идентификатор окружения.
- `code` (TEXT, UNIQUE, NOT NULL) — код окружения: `dev|stage|prod`.
- `name` (TEXT, NOT NULL) — отображаемое название окружения.

Назначение: фиксированный справочник окружений.

### 3) `configs`
- `id` (UUID, PK) — идентификатор логической конфигурации.
- `service_id` (UUID, FK -> `services.id`, NOT NULL) — владелец конфигурации (сервис).
- `environment_id` (SMALLINT, FK -> `environments.id`, NOT NULL) — окружение конфигурации.
- `config_key` (TEXT, NOT NULL) — ключ конфигурации в рамках service+environment.
- `config_type` (TEXT, NOT NULL) — тип данных: `config|secret`.
- `format` (TEXT, NOT NULL) — формат полезной нагрузки: `kv|json|yaml`.
- `status` (TEXT, NOT NULL) — состояние записи: `active|deleted` (soft-delete).
- `current_version` (BIGINT, NOT NULL, default 0) — текущая актуальная версия конфигурации.
- `created_by` (TEXT, NOT NULL) — инициатор создания (user/service id).
- `created_at` (TIMESTAMPTZ, NOT NULL) — время создания.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время последнего изменения метаданных/статуса.
- `deleted_at` (TIMESTAMPTZ, NULL) — время soft-delete (если удалена).

Назначение: агрегат верхнего уровня (конфигурация в рамках service+environment).

Уникальность:
- `(service_id, environment_id, config_key)` — одна логическая конфигурация на ключ в окружении.

### 4) `config_versions`
- `id` (UUID, PK) — идентификатор версии.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — ссылка на конфигурацию.
- `version` (BIGINT, NOT NULL) — номер версии (монотонно растет в рамках `config_id`).
- `payload` (JSONB, NOT NULL) — нормализованная полезная нагрузка версии.
- `payload_hash` (TEXT, NOT NULL) — хеш payload для контроля целостности/сравнения.
- `is_secret` (BOOLEAN, NOT NULL) — признак, что версия содержит секретные данные.
- `encrypted_payload` (BYTEA, NULL) — зашифрованный payload (обязательно для секрета).
- `encryption_key_ref` (TEXT, NULL) — ссылка на ключ/версию ключа шифрования.
- `change_reason` (TEXT, NULL) — комментарий/причина изменения.
- `change_type` (TEXT, NOT NULL) — тип изменения: `create|update|rollback|delete`.
- `created_by` (TEXT, NOT NULL) — инициатор изменения.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время фиксации версии.
- `source_ip` (INET, NULL) — IP источника запроса.

Назначение: неизменяемая история версий, включая rollback как новую версию.

Уникальность:
- `(config_id, version)` — монотонность и уникальность номера версии в рамках конфигурации.

### 5) `rollouts`
- `id` (UUID, PK) — идентификатор rollout-операции.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — конфигурация, к которой относится rollout.
- `target_version` (BIGINT, NOT NULL) — версия, доставляемая в рамках rollout.
- `strategy` (TEXT, NOT NULL) — стратегия: `instant|gradual|canary`.
- `status` (TEXT, NOT NULL) — состояние rollout: `pending|running|paused|stopped|rolled_back|completed|failed`.
- `criteria` (JSONB, NULL) — критерии отбора клиентов (в т.ч. canary).
- `percentage` (SMALLINT, NULL) — доля клиентов для gradual rollout (0..100).
- `started_by` (TEXT, NOT NULL) — инициатор запуска.
- `started_at` (TIMESTAMPTZ, NOT NULL) — время старта.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время последнего изменения состояния.
- `stopped_at` (TIMESTAMPTZ, NULL) — время остановки/завершения (если применимо).
- `rollback_to_version` (BIGINT, NULL) — версия, к которой выполнен откат rollout.

Назначение: управление жизненным циклом rollout.

### 6) `delivery_outbox`
- `id` (UUID, PK) — идентификатор outbox-сообщения.
- `config_id` (UUID, NOT NULL) — конфигурация события доставки.
- `version` (BIGINT, NOT NULL) — версия, доставляемая событием.
- `channel` (TEXT, NOT NULL) — канал публикации в Centrifugo.
- `event_type` (TEXT, NOT NULL) — тип события: `config.updated|config.rollback|config.deleted`.
- `payload` (JSONB, NOT NULL) — сериализованное событие доставки.
- `status` (TEXT, NOT NULL) — статус публикации: `pending|publishing|published|failed|dead`.
- `attempt_count` (INT, NOT NULL, default 0) — число попыток публикации.
- `next_attempt_at` (TIMESTAMPTZ, NULL) — когда выполнять следующую попытку.
- `last_error` (TEXT, NULL) — текст последней ошибки публикации.
- `published_at` (TIMESTAMPTZ, NULL) — время успешной публикации.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время создания outbox-записи.

Назначение: transactional outbox для асинхронной публикации в Centrifugo.

Уникальность:
- `(config_id, version, event_type)` — идемпотентность публикации события.

### 7) `client_agents`
- `id` (UUID, PK) — внутренний идентификатор агента.
- `agent_uid` (TEXT, UNIQUE, NOT NULL) — внешний стабильный идентификатор агента/инстанса.
- `service_id` (UUID, FK -> `services.id`, NOT NULL) — сервис, к которому относится агент.
- `environment_id` (SMALLINT, FK -> `environments.id`, NOT NULL) — окружение агента.
- `metadata` (JSONB, NULL) — произвольные атрибуты агента (host, zone, tags и т.д.).
- `last_seen_at` (TIMESTAMPTZ, NULL) — последнее наблюдение активности агента.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время регистрации агента.

Назначение: реестр клиентских агентов и их области.

### 8) `agent_config_state`
- `agent_id` (UUID, FK -> `client_agents.id`, NOT NULL) — агент.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — конфигурация.
- `applied_version` (BIGINT, NOT NULL) — последняя версия, примененная агентом.
- `apply_status` (TEXT, NOT NULL) — результат применения: `applied|rejected|pending`.
- `last_error` (TEXT, NULL) — текст последней ошибки применения.
- `updated_at` (TIMESTAMPTZ, NOT NULL) — время последнего обновления состояния.
- PK (`agent_id`, `config_id`) — один state на пару агент-конфигурация.

Назначение: состояние применения версии агентом, для reconciliation и detection slow clients.

### 9) `delivery_receipts`
- `id` (UUID, PK) — идентификатор receipt-события.
- `config_id` (UUID, FK -> `configs.id`, NOT NULL) — конфигурация.
- `version` (BIGINT, NOT NULL) — версия конфигурации.
- `agent_id` (UUID, FK -> `client_agents.id`, NOT NULL) — агент, приславший receipt.
- `receipt_status` (TEXT, NOT NULL) — статус: `applied|rejected`.
- `error_message` (TEXT, NULL) — причина отказа, если `rejected`.
- `received_at` (TIMESTAMPTZ, NOT NULL) — время получения подтверждения.

Назначение: факт успешного/неуспешного применения конфигурации агентом.

Уникальность:
- `(config_id, version, agent_id)` — один receipt на версию для агента.

### 10) `audit_log`
- `id` (UUID, PK) — идентификатор записи аудита.
- `operation` (TEXT, NOT NULL) — операция (`config.create`, `config.update`, `rollback`, `delivery.publish` и т.п.).
- `entity_type` (TEXT, NOT NULL) — тип сущности (`config`, `version`, `rollout`, `secret`, `delivery`).
- `entity_id` (UUID, NULL) — идентификатор сущности операции (если применимо).
- `service_id` (UUID, NULL, FK -> `services.id`) — сервисный контекст операции.
- `config_id` (UUID, NULL, FK -> `configs.id`) — конфигурация в контексте операции.
- `version` (BIGINT, NULL) — версия, связанная с событием.
- `actor_id` (TEXT, NOT NULL) — идентификатор инициатора (user/service).
- `actor_type` (TEXT, NOT NULL) — тип инициатора: `user|service`.
- `source_ip` (INET, NULL) — источник запроса.
- `correlation_id` (TEXT, NULL) — идентификатор трассировки цепочки вызовов.
- `diff` (JSONB, NULL) — diff для операций изменения конфигураций/секретов.
- `meta` (JSONB, NULL) — расширенные атрибуты события.
- `created_at` (TIMESTAMPTZ, NOT NULL) — время записи аудита.

Назначение: неизменяемый журнал действий и delivery-событий.

## Связи и кардинальности
- `services (1) -> (N) configs`
- `environments (1) -> (N) configs`
- `configs (1) -> (N) config_versions`
- `configs (1) -> (N) rollouts`
- `configs (1) -> (N) delivery_outbox`
- `services (1) -> (N) client_agents`
- `client_agents (N) <-> (N) configs` через `agent_config_state`
- `configs (1) -> (N) delivery_receipts`
- `client_agents (1) -> (N) delivery_receipts`
- `services/configs (1) -> (N) audit_log`

## Ключевые ограничения
- Версия конфигурации уникальна в рамках `config_id`.
- Для секретов `config_type='secret'` требуется `encrypted_payload IS NOT NULL`.
- `percentage` для gradual rollout в диапазоне 0..100.
- `environments` ограничены на уровне справочника: `dev`, `stage`, `prod`.
- Soft-delete для `configs`: `status='deleted'`, данные версий сохраняются.

## Индексация (минимальный набор)
- `configs(service_id, environment_id)`
- `configs(environment_id)`
- `config_versions(config_id, version DESC)`
- `delivery_outbox(status, next_attempt_at)`
- `audit_log(service_id, created_at DESC)`
- `audit_log(actor_id, created_at DESC)`
- `audit_log(created_at DESC)`
- `agent_config_state(config_id, applied_version)`

## Явные допущения
- Для совместимости с форматами `kv/json/yaml` поле `payload` хранится в `JSONB`; для `yaml` исходный вид может дополнительно храниться в `meta` или восстанавливаться на уровне приложения.
- Секреты хранятся как encrypted blob + reference на ключ; конкретный key-provider (например, KMS/Vault) остается внешним.
- ACK/Error от клиента не являются публичным API, но фиксируются во внутренних таблицах `delivery_receipts` и `agent_config_state`.
