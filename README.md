# Distributed Real-Time Configuration Delivery Platform Docs

## Документация

- [Требования (requirements.md)](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/requirements.md) — исходное ТЗ, на основе которого подготовлены архитектура, БД и API.

### Архитектура (C4)
- [System Context (L1)](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/docs/architecture/system-context.md) — внешние акторы, границы системы и ключевые сценарии взаимодействия.
- [Container (L2)](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/docs/architecture/container.md) — контейнеры платформы и их взаимодействия (API, publisher, PostgreSQL, Centrifugo, observability).
- [Component (L3) — Config API Service](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/docs/architecture/component-config-api.md) — внутренняя декомпозиция ключевого контейнера и поток критической операции update.

### База данных
- [ER-модель](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/docs/database/er-model.md) — логическая схема БД: сущности, поля, связи, кардинальности и ограничения.
- [SQL DDL](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/docs/database/schema.sql) — PostgreSQL-скрипт создания таблиц, индексов и ограничений.

### API
- [OpenAPI 3.0.3 спецификация](/Users/a.s.lushnikova/IdeaProjects/orangevk/docs/docs/api/openapi.yaml) — контракты REST API: endpoints, request/response схемы, коды ответов, ошибки и security.
