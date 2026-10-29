# Sequence диаграмма: смена тарифа

```mermaid
sequenceDiagram
    autonumber
    actor OP as Оператор
    participant CRM
    participant ESB
    participant BILL as Биллинг (SOAP)
    participant MQ as Kafka
    participant NOTIF as Сервис уведомлений

    OP->>CRM: Выбрать «Сменить тариф»
    CRM->>ESB: GET /subscribers/{msisdn}/available-tariffs
    ESB->>BILL: SOAP GetAvailableTariffs
    BILL-->>ESB: Список тарифов
    ESB-->>CRM: 200 OK [тарифы]
    OP->>CRM: Выбрать тариф и дату
    CRM->>ESB: POST /subscribers/{msisdn}/tariff-changes<br/>X-Request-Id: uuid

    alt requestId уже обработан
        ESB-->>CRM: 200 OK (сохранённый результат)
    else новый запрос
        ESB->>ESB: Валидация, маппинг JSON → XML
        ESB->>BILL: SOAP ChangeTariffPlan
        alt успех
            BILL-->>ESB: Result=OK, operationId
            ESB->>MQ: publish tariff.changed
            ESB-->>CRM: 201 Created {status: APPLIED}
            CRM-->>OP: «Тариф изменён»
            MQ-->>NOTIF: tariff.changed
            NOTIF->>NOTIF: Отправить SMS абоненту
        else недостаточно средств
            BILL-->>ESB: Fault: INSUFFICIENT_FUNDS
            ESB-->>CRM: 422 {code: INSUFFICIENT_FUNDS}
            CRM-->>OP: «Недостаточно средств»
        else таймаут > 10 c
            ESB-->>CRM: 503 {code: BILLING_UNAVAILABLE}
            CRM-->>OP: «Повторите позже»
        end
    end
```

**Почему так:**

- **Синхронный ответ CRM** нужен, потому что оператор ждёт результат на экране.
- **SMS идёт асинхронно через Kafka**, чтобы медленная отправка SMS не задерживала ответ оператору и не могла откатить уже выполненную смену.
- **Заголовок `X-Request-Id`** обеспечивает идемпотентность: повтор после таймаута не создаёт второй смены тарифа.

## Исходник PlantUML

```plantuml
@startuml
autonumber
actor "Оператор" as OP
participant CRM
participant ESB
participant "Биллинг\n(SOAP)" as BILL
queue Kafka as MQ
participant "Сервис\nуведомлений" as NOTIF

OP -> CRM : Сменить тариф
CRM -> ESB : GET /subscribers/{msisdn}/available-tariffs
ESB -> BILL : GetAvailableTariffs
BILL --> ESB : тарифы
ESB --> CRM : 200 OK
OP -> CRM : выбрать тариф, дату
CRM -> ESB : POST /subscribers/{msisdn}/tariff-changes\nX-Request-Id
alt requestId уже обработан
  ESB --> CRM : 200 OK (сохранённый результат)
else новый запрос
  ESB -> ESB : валидация, JSON → XML
  ESB -> BILL : ChangeTariffPlan
  alt успех
    BILL --> ESB : OK, operationId
    ESB -> MQ : tariff.changed
    ESB --> CRM : 201 Created
    CRM --> OP : «Тариф изменён»
    MQ --> NOTIF : tariff.changed
  else недостаточно средств
    BILL --> ESB : Fault INSUFFICIENT_FUNDS
    ESB --> CRM : 422
  else таймаут
    ESB --> CRM : 503 BILLING_UNAVAILABLE
  end
end
@enduml
```
