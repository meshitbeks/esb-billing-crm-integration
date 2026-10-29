# Use Case диаграмма

```mermaid
flowchart LR
    OP(["👤 Оператор контакт-центра"])
    BILL(["⚙️ Биллинг"])
    NOTIF(["⚙️ Сервис уведомлений"])

    subgraph SYS ["Сервис смены тарифа (CRM + ESB)"]
        UC1(["Сменить тарифный план"])
        UC2(["Получить доступные тарифы"])
        UC3(["Проверить баланс"])
        UC4(["Отправить SMS абоненту"])
        UC5(["Посмотреть историю смен тарифа"])
    end

    OP --- UC1
    OP --- UC5
    UC1 -. "include" .-> UC2
    UC1 -. "include" .-> UC3
    UC4 -. "extend" .-> UC1
    UC3 --- BILL
    UC2 --- BILL
    UC4 --- NOTIF
```

**Как читать:** «Сменить тариф» всегда включает (`include`) получение доступных тарифов и проверку баланса. Отправка SMS расширяет (`extend`) основной сценарий: она выполняется после успешной смены, и её сбой не отменяет смену тарифа.

## Исходник PlantUML

```plantuml
@startuml
left to right direction
actor "Оператор\nконтакт-центра" as OP
actor "Биллинг" as BILL <<system>>
actor "Сервис\nуведомлений" as NOTIF <<system>>

rectangle "Сервис смены тарифа (CRM + ESB)" {
  usecase "Сменить тарифный план" as UC1
  usecase "Получить доступные тарифы" as UC2
  usecase "Проверить баланс" as UC3
  usecase "Отправить SMS абоненту" as UC4
  usecase "Посмотреть историю\nсмен тарифа" as UC5
}

OP --> UC1
OP --> UC5
UC1 .> UC2 : <<include>>
UC1 .> UC3 : <<include>>
UC4 .> UC1 : <<extend>>
UC2 --> BILL
UC3 --> BILL
UC4 --> NOTIF
@enduml
```
