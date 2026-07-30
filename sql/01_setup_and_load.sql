/* =============================================================================
   БЛОК 0. Развёртывание схемы и загрузка сырых логов
   -----------------------------------------------------------------------------
   Датасет: eCommerce events history (REES46 Marketing Platform, Kaggle).
   Гранулярность: одна строка = одно событие пользователя с товаром.

   Ключевое решение по загрузке: данные грузятся в ДВА этапа —
   сначала в staging-таблицу из TEXT-колонок, затем приводятся к целевым типам.
   Так сделано намеренно: в исходном CSV пустые значения brand / category_code
   записаны как пустые строки, а не как NULL, и прямой COPY в типизированную
   таблицу падает на первой же такой строке, откатывая весь импорт.
   ========================================================================== */


-- Данные в датасете записаны в UTC. DATE_TRUNC по колонке TIMESTAMPTZ зависит
-- от часового пояса сессии, поэтому фиксируем UTC явно — иначе границы суток
-- «поедут» и DAU будет считаться некорректно.
SET TIME ZONE 'UTC';


/* -----------------------------------------------------------------------------
   Шаг 1. Staging-таблица: все колонки как TEXT, чтобы загрузка не падала
   на нестандартных значениях. Валидацию делаем на следующем шаге.
-------------------------------------------------------------------------- */
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


/* -----------------------------------------------------------------------------
   Шаг 2. Загрузка CSV.
   Путь /data/events.csv — это примонтированная папка ./data из docker-compose.
   При запуске вне Docker замените на локальный путь и используйте \copy
   (клиентская команда psql) вместо COPY (серверная, требует прав суперпользователя).
-------------------------------------------------------------------------- */
COPY events_raw
FROM '/data/events.csv'
WITH (FORMAT csv, HEADER true);


/* -----------------------------------------------------------------------------
   Шаг 3. Целевая таблица с корректными типами данных.
-------------------------------------------------------------------------- */
DROP TABLE IF EXISTS events;

CREATE TABLE events (
    event_time      TIMESTAMPTZ,    -- время события (UTC)
    event_type      VARCHAR(20),    -- 'view' | 'cart' | 'remove_from_cart' | 'purchase'
    product_id      BIGINT,
    category_id     BIGINT,
    category_code   VARCHAR(200),   -- иерархия категории, часто отсутствует
    brand           VARCHAR(100),   -- бренд в нижнем регистре, часто отсутствует
    price           NUMERIC(10, 2),
    user_id         BIGINT,
    user_session    UUID            -- идентификатор сессии, ключ для воронки
);


/* -----------------------------------------------------------------------------
   Шаг 4. Перенос данных с приведением типов.
   NULLIF(col, '') превращает пустые строки в честные NULL — иначе они попадут
   в GROUP BY как отдельная «категория» и исказят агрегаты по брендам.
-------------------------------------------------------------------------- */
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
    event_time::TIMESTAMPTZ,        -- формат '2020-04-01 10:15:22 UTC' парсится штатно
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


/* -----------------------------------------------------------------------------
   Шаг 5. Индексы.
   Подобраны под конкретные запросы проекта, а не «на всякий случай»:
     * (user_id, event_time)    — когортный анализ, поиск первой активности;
     * (user_session, ...)      — сборка воронки внутри сессии;
     * (event_time)             — оконные срезы DAU / WAU / MAU.
-------------------------------------------------------------------------- */
CREATE INDEX idx_events_user_time    ON events (user_id, event_time);
CREATE INDEX idx_events_session_time ON events (user_session, event_time);
CREATE INDEX idx_events_time         ON events (event_time);

-- Частичный индекс: воронка обращается только к трём типам событий из четырёх,
-- поэтому индексировать remove_from_cart смысла нет.
CREATE INDEX idx_events_funnel
    ON events (event_type, event_time)
    WHERE event_type IN ('view', 'cart', 'purchase');

-- Обновляем статистику планировщика после массовой загрузки
ANALYZE events;


/* -----------------------------------------------------------------------------
   Шаг 6. Проверки качества данных.
   Запускать сразу после загрузки: результат определяет, сколько столбцов
   удержания появится в когортной таблице (Блок 3).
-------------------------------------------------------------------------- */

-- 6.1. Общий объём и покрытие по времени
SELECT
    COUNT(*)                                    AS total_events,
    COUNT(DISTINCT user_id)                     AS unique_users,
    COUNT(DISTINCT user_session)                AS unique_sessions,
    MIN(event_time)::DATE                       AS first_day,
    MAX(event_time)::DATE                       AS last_day,
    COUNT(DISTINCT DATE_TRUNC('month', event_time)) AS months_covered
FROM events;

-- 6.2. Распределение типов событий: показывает «форму» воронки до расчётов
SELECT
    event_type,
    COUNT(*)                                              AS events_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)    AS share_pct
FROM events
GROUP BY event_type
ORDER BY events_count DESC;

-- 6.3. Пропуски в ключевых полях.
-- user_session критичен: сессии с NULL выпадут из воронки в Блоке 2.
SELECT
    COUNT(*) FILTER (WHERE user_id IS NULL)       AS null_user_id,
    COUNT(*) FILTER (WHERE user_session IS NULL)  AS null_user_session,
    COUNT(*) FILTER (WHERE brand IS NULL)         AS null_brand,
    COUNT(*) FILTER (WHERE category_code IS NULL) AS null_category_code,
    COUNT(*) FILTER (WHERE price IS NULL)         AS null_price
FROM events;
