-- Фиксируем UTC, чтобы DATE_TRUNC и DAU не уплыли из-за локальной часовой зоны
SET TIME ZONE 'UTC';

-- -----------------------------------------------------------------------------
-- 1. STAGING
-- Грузим в TEXT, так как в сыром CSV пустые поля brand/category_code идут 
-- как "", а не NULL. Прямой COPY в типизированную таблицу падает.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS events_raw;

CREATE TABLE events_raw (
    event_time      TEXT,
    event_type      TEXT,
    product_id      TEXT,
    category_id     TEXT,
    category_code   TEXT,
    brand           TEXT,
    price           TEXT,
    user_id         TEXT,
    user_session    TEXT
);

-- Если запускаете локально без Docker, заменяйте на \copy
COPY events_raw
FROM '/data/events.csv'
WITH (FORMAT csv, HEADER true);

-- -----------------------------------------------------------------------------
-- 2. TARGET TABLE
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    event_time      TIMESTAMPTZ,
    event_type      VARCHAR(20),
    product_id      BIGINT,
    category_id     BIGINT,
    category_code   VARCHAR(200),
    brand           VARCHAR(100),
    price           NUMERIC(10, 2),
    user_id         BIGINT,
    user_session    UUID
);

-- Вычищаем пустые строки через NULLIF, иначе пустые бренды/категории
-- залипнут в GROUP BY как отдельные значения
INSERT INTO events (
    event_time,
    event_type,
    product_id,
    category_id,
    category_code,
    brand,
    price,
    user_id,
    user_session
)
SELECT
    event_time::TIMESTAMPTZ,
    event_type,
    NULLIF(product_id, '')::BIGINT,
    NULLIF(category_id, '')::BIGINT,
    NULLIF(category_code, ''),
    NULLIF(brand, ''),
    NULLIF(price, '')::NUMERIC,
    NULLIF(user_id, '')::BIGINT,
    NULLIF(user_session, '')::UUID
FROM events_raw;

DROP TABLE events_raw;

-- -----------------------------------------------------------------------------
-- 3. INDEXES & ANALYZE
-- -----------------------------------------------------------------------------
CREATE INDEX idx_events_user_time    ON events (user_id, event_time);
CREATE INDEX idx_events_session_time ON events (user_session, event_time);
CREATE INDEX idx_events_time         ON events (event_time);

-- Частичный индекс под воронку (remove_from_cart там не используется)
CREATE INDEX idx_events_funnel
    ON events (event_type, event_time)
    WHERE event_type IN ('view', 'cart', 'purchase');

ANALYZE events;

-- -----------------------------------------------------------------------------
-- 4. SANITY CHECKS
-- -----------------------------------------------------------------------------

-- Объемы и диапазоны дат
SELECT
    COUNT(*)                                         AS total_events,
    COUNT(DISTINCT user_id)                          AS unique_users,
    COUNT(DISTINCT user_session)                     AS unique_sessions,
    MIN(event_time)::DATE                            AS first_day,
    MAX(event_time)::DATE                            AS last_day,
    COUNT(DISTINCT DATE_TRUNC('month', event_time))  AS months_covered
FROM events;

-- Сплит по типам событий
SELECT
    event_type,
    COUNT(*)                                           AS events_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS share_pct
FROM events
GROUP BY event_type
ORDER BY events_count DESC;

-- Проверка пропусков
SELECT
    COUNT(*) FILTER (WHERE user_id IS NULL)       AS null_user_id,
    COUNT(*) FILTER (WHERE user_session IS NULL)  AS null_user_session,
    COUNT(*) FILTER (WHERE brand IS NULL)         AS null_brand,
    COUNT(*) FILTER (WHERE category_code IS NULL) AS null_category_code,
    COUNT(*) FILTER (WHERE price IS NULL)         AS null_price
FROM events;