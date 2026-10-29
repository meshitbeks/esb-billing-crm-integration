-- Модель данных сервиса смены тарифа (PostgreSQL)
-- Хранится на стороне ESB: журнал смен и ключи идемпотентности.

CREATE TABLE tariff (
    code          VARCHAR(30)    PRIMARY KEY,               -- код тарифа (SMART_10)
    name          VARCHAR(100)   NOT NULL,
    monthly_fee   NUMERIC(12, 2) NOT NULL CHECK (monthly_fee >= 0),
    billing_plan_id INTEGER      NOT NULL UNIQUE,            -- ID тарифа в биллинге (для маппинга)
    is_active     BOOLEAN        NOT NULL DEFAULT TRUE
);

CREATE TABLE tariff_change (
    change_id            UUID         PRIMARY KEY,
    request_id           UUID         NOT NULL UNIQUE,       -- X-Request-Id: защита от дублей
    msisdn               VARCHAR(11)  NOT NULL,
    old_tariff_code      VARCHAR(30)  NOT NULL REFERENCES tariff (code),
    new_tariff_code      VARCHAR(30)  NOT NULL REFERENCES tariff (code),
    status               VARCHAR(20)  NOT NULL CHECK (status IN ('APPLIED', 'SCHEDULED', 'FAILED')),
    effective_date       DATE         NOT NULL,
    channel              VARCHAR(20)  NOT NULL CHECK (channel IN ('CRM', 'MOBILE_APP')),
    operator_id          VARCHAR(50),
    billing_operation_id VARCHAR(50),
    error_code           VARCHAR(50),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (old_tariff_code <> new_tariff_code)
);

-- История абонента запрашивается по номеру, новые сверху
CREATE INDEX idx_tariff_change_msisdn_created ON tariff_change (msisdn, created_at DESC);

-- Ключи идемпотентности: сохранённый ответ на 24 часа
CREATE TABLE idempotency_key (
    request_id     UUID        PRIMARY KEY,
    http_status    SMALLINT    NOT NULL,
    response_body  JSONB       NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at     TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours'
);

CREATE INDEX idx_idempotency_expires ON idempotency_key (expires_at);
