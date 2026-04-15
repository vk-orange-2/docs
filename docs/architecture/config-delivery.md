Диаграмма для кейса:
- Без Centrifugo history
- С отправкой конфигов целиком, без диффов

В целом должно работать с небольшими изменениями для history + отправки диффов

Блок диаграммы после дисконнекта показывает, как Client SDK будет обрабатывать catch-up к актуальной версии конфига
Основная идея - сначала начинаем слушать канал, только потом запрашиваем latest конфиг

```mermaid
sequenceDiagram
    autonumber
    participant Client
    actor Admin
    participant ConfigService
    participant DeliveryService as DeliveryService (Centrifugo)

    activate Client
    Client ->> DeliveryService: Subscribe to channel :namespace/:service/:stand

    Client ->> ConfigService: Request latest config
    ConfigService -->> Client: config v1

    Client-->>Client: Apply v1

    Admin ->> ConfigService: config update v2
    ConfigService ->> DeliveryService: propagate config update

    DeliveryService -->> Client: config v2

    Client-->>Client: Apply v2

    Client -x- DeliveryService: Disconnect

    activate Client
    Client ->> DeliveryService: Subscribe to channel :namespace/:service/:stand

    par Admin makes new update
        Admin ->> ConfigService: config update v3
        ConfigService ->> DeliveryService: propagate config update
        DeliveryService -->> Client: config v3
    and Client requests latest config
        Client ->> ConfigService: Request latest config
        ConfigService -->> Client: config v2
    end

    Client -->> Client: Compare v2 and v3, apply v3
    deactivate Client
```
