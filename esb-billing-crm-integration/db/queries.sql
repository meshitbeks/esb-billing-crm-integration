-- Запросы аналитика для проверки данных и разбора инцидентов

-- 1. История смен тарифа абонента, новые сверху
SELECT change_id, old_tariff_code, new_tariff_code, status, effective_date, channel, created_at
FROM tariff_change
WHERE msisdn = '77071234567'
ORDER BY created_at DESC
LIMIT 20;

-- 2. Неуспешные смены за последние сутки по кодам ошибок
SELECT error_code, COUNT(*) AS cnt
FROM tariff_change
WHERE status = 'FAILED'
  AND created_at >= now() - INTERVAL '1 day'
GROUP BY error_code
ORDER BY cnt DESC;

-- 3. Поиск возможных дублей: больше одной успешной смены абонента за 5 минут
SELECT msisdn, COUNT(*) AS changes, MIN(created_at) AS first_at, MAX(created_at) AS last_at
FROM tariff_change
WHERE status IN ('APPLIED', 'SCHEDULED')
GROUP BY msisdn, date_trunc('hour', created_at), floor(EXTRACT(MINUTE FROM created_at) / 5)
HAVING COUNT(*) > 1;

-- 4. Самые популярные переходы между тарифами за месяц (для бизнеса)
SELECT t_old.name AS from_tariff, t_new.name AS to_tariff, COUNT(*) AS cnt
FROM tariff_change tc
JOIN tariff t_old ON t_old.code = tc.old_tariff_code
JOIN tariff t_new ON t_new.code = tc.new_tariff_code
WHERE tc.status = 'APPLIED'
  AND tc.created_at >= date_trunc('month', now())
GROUP BY t_old.name, t_new.name
ORDER BY cnt DESC
LIMIT 10;

-- 5. Запланированные смены на ближайшее 1-е число (для сверки с биллингом)
SELECT msisdn, old_tariff_code, new_tariff_code, effective_date
FROM tariff_change
WHERE status = 'SCHEDULED'
  AND effective_date = date_trunc('month', now() + INTERVAL '1 month')::date
ORDER BY msisdn;
