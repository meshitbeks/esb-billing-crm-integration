# 2. Техническое задание на интеграцию

**Сервис:** ESB Tariff Service · **Версия:** 1.0 · **Связанные документы:** [бизнес-требования](01-business-requirements.md), [API-контракт](../api/openapi.yaml), [sequence](../diagrams/sequence.md)

## 2.1 Участники интеграции

| Система | Роль | Протокол | Направление |
| --- | --- | --- | --- |
| CRM | Потребитель | REST / JSON, HTTPS | CRM → ESB |
| ESB | Оркестратор, трансформация, маршрутизация | — | — |
| Биллинг | Поставщик (legacy) | SOAP 1.1 / XML | ESB → Биллинг |
| Kafka | Брокер сообщений | Kafka, JSON | ESB → топик `billing.tariff.changed.v1` |
| Сервис уведомлений, DWH | Подписчики события | Kafka | Топик → подписчики |

**Почему ESB, а не прямая интеграция CRM ↔ биллинг:** второй этап (мобильное приложение) переиспользует тот же сервис; изменения формата биллинга затрагивают только ESB; логирование и мониторинг собраны в одном месте.

## 2.2 Методы

| Метод | Назначение | Тип |
| --- | --- | --- |
| `GET /subscribers/{msisdn}/available-tariffs` | Доступные тарифы | синхронный |
| `POST /subscribers/{msisdn}/tariff-changes` | Смена тарифа | синхронный |
| `GET /subscribers/{msisdn}/tariff-changes` | История смен | синхронный |
| Событие `tariff.changed` | Уведомление подписчиков | асинхронный |

Полное описание полей, кодов ответов и примеров приведено в [openapi.yaml](../api/openapi.yaml).

## 2.3 Логика обработки `POST /tariff-changes` в ESB

1. Проверить JWT-токен. При ошибке вернуть `401`.
2. Проверить заголовок `X-Request-Id`. Если такой ключ уже обработан за последние 24 часа, вернуть сохранённый ответ с кодом `200` и не вызывать биллинг.
3. Провалидировать тело по схеме `TariffChangeRequest`. При ошибке вернуть `400 VALIDATION_ERROR`.
4. Проверить, нет ли незавершённой смены тарифа для этого `msisdn` (блокировка по номеру). Если есть, вернуть `409 CHANGE_IN_PROGRESS`.
5. Преобразовать запрос в SOAP `ChangeTariffPlan` (маппинг в 2.4) и вызвать биллинг с таймаутом 10 секунд.
6. Обработать ответ биллинга по таблице 2.5.
7. При успехе:
   - сохранить запись в `tariff_change`;
   - сохранить ответ по ключу `X-Request-Id`;
   - опубликовать событие `tariff.changed`;
   - вернуть `201`.
8. Снять блокировку по `msisdn`.

## 2.4 Маппинг полей CRM (JSON) → Биллинг (SOAP)

| CRM / REST | Биллинг / SOAP | Преобразование |
| --- | --- | --- |
| `msisdn` (path) | `ChangeTariffPlan/SubscriberNumber` | без изменений |
| `newTariffCode` | `ChangeTariffPlan/TariffPlanId` | справочник `tariff_code → billing_plan_id` в ESB |
| `effectiveMode` = `IMMEDIATE` | `ChangeTariffPlan/ApplyDate` | текущая дата (Asia/Almaty) |
| `effectiveMode` = `NEXT_MONTH` | `ChangeTariffPlan/ApplyDate` | 1-е число следующего месяца |
| `channel` | `ChangeTariffPlan/SalesChannel` | `CRM` → `CC`, `MOBILE_APP` → `APP` |
| `operatorId` | `ChangeTariffPlan/UserLogin` | без изменений |
| `X-Request-Id` | `ChangeTariffPlan/ExternalId` | для сверки и защиты от дублей в биллинге |

Пример SOAP-запроса, который формирует ESB:

```xml
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:bil="http://billing.example.kz/tariff">
  <soapenv:Body>
    <bil:ChangeTariffPlan>
      <bil:SubscriberNumber>77071234567</bil:SubscriberNumber>
      <bil:TariffPlanId>1042</bil:TariffPlanId>
      <bil:ApplyDate>2026-10-29</bil:ApplyDate>
      <bil:SalesChannel>CC</bil:SalesChannel>
      <bil:UserLogin>op-10452</bil:UserLogin>
      <bil:ExternalId>9a7c3e1b-2f4d-4b6a-8c0e-1d2f3a4b5c6d</bil:ExternalId>
    </bil:ChangeTariffPlan>
  </soapenv:Body>
</soapenv:Envelope>
```

## 2.5 Обработка ответов биллинга

| Ответ биллинга | HTTP-ответ ESB → CRM | Код ошибки | Сообщение оператору |
| --- | --- | --- | --- |
| `Result = OK` | 201 | — | «Тариф изменён» / «Тариф будет изменён с 01.11» |
| Fault `ERR_101` (баланс) | 422 | `INSUFFICIENT_FUNDS` | «Недостаточно средств: нужно N ₸» |
| Fault `ERR_102` (тариф недоступен) | 422 | `TARIFF_NOT_AVAILABLE` | «Тариф недоступен абоненту» |
| Fault `ERR_201` (абонент не найден) | 404 | `SUBSCRIBER_NOT_FOUND` | «Абонент не найден» |
| Таймаут > 10 с, 5xx, обрыв | 503 + `Retry-After: 30` | `BILLING_UNAVAILABLE` | «Сервис временно недоступен, повторите позже» |

При таймауте ESB **не повторяет** вызов автоматически, потому что биллинг мог успеть применить смену. Повтор делает CRM с тем же `X-Request-Id`, а биллинг отсекает дубль по `ExternalId`.

## 2.6 Событие `tariff.changed` (Kafka)

- **Топик:** `billing.tariff.changed.v1`
- **Ключ сообщения:** `msisdn`. Все события одного абонента попадают в один раздел (partition), поэтому сохраняется порядок.
- **Гарантия доставки:** at-least-once. Подписчики обязаны отбрасывать дубли по `changeId`.

```json
{
  "eventId": "c3d4e5f6-0718-4a2b-9c3d-4e5f60718293",
  "eventType": "tariff.changed",
  "occurredAt": "2026-10-29T10:15:30+05:00",
  "changeId": "5b1f0a2c-8d7e-4c1a-9f3e-2a6b7c8d9e01",
  "msisdn": "77071234567",
  "oldTariffCode": "SMART_5",
  "newTariffCode": "SMART_10",
  "status": "APPLIED",
  "effectiveDate": "2026-10-29",
  "channel": "CRM"
}
```

## 2.7 Логирование

Каждый запрос логируется в ESB с полями:
- `X-Correlation-Id`, `X-Request-Id`, `msisdn` (маскированный: `7707***4567`);
- метод, HTTP-код, время ответа биллинга, код ошибки.

Тело SOAP-запроса и ответа пишется в лог только на уровне DEBUG. Персональные данные абонента в логах не хранятся.

**Как искать проблему:** оператор сообщает номер абонента и время → по `msisdn` и времени находим `X-Correlation-Id` → по нему находим весь путь запроса в CRM, ESB и биллинге.

## 2.8 Нефункциональные требования

| Параметр | Значение |
| --- | --- |
| Время ответа `POST /tariff-changes` | p95 ≤ 3 с (без учёта таймаута биллинга) |
| Таймаут вызова биллинга | 10 с |
| Нагрузка | до 20 запросов в секунду в пике |
| Доступность сервиса ESB | 99,9% в месяц |
| Хранение ключей идемпотентности | 24 часа |
| Безопасность | HTTPS, JWT от сервиса авторизации, роль `crm-operator` |

## 2.9 Открытые вопросы к команде биллинга

1. Поддерживает ли биллинг проверку дубля по `ExternalId`? Если нет, защиту от дублей полностью берёт на себя ESB.
2. Есть ли у биллинга ограничение на количество запросов в секунду (rate limit)?
3. Нужен ли отдельный метод отмены запланированной смены (`SCHEDULED`)?
