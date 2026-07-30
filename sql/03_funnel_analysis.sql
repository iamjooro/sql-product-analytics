/* =============================================================================
   БЛОК 2. Анализ продуктовой воронки (Funnel Analysis)
   -----------------------------------------------------------------------------
   Воронка: View (просмотр) -> Cart (добавление в корзину) -> Purchase (покупка).

   Три методологических решения, определяющих корректность расчёта:

   1) Единица анализа — СЕССИЯ (user_session), а не пользователь.
      Воронка описывает поведение внутри одного визита; если считать по
      пользователям, конверсия будет завышена: человек мог смотреть товар
      в январе, а купить в марте — это не «прохождение воронки», а два
      разных сценария.

   2) Шаги засчитываются только в ХРОНОЛОГИЧЕСКОМ порядке.
      Наивный подход (проверить «в сессии есть view И есть cart») ошибочен:
      он засчитает сессию, где пользователь пришёл по прямой ссылке в корзину
      и только потом открыл карточку товара. Здесь каждый следующий шаг ищется
      строго ПОСЛЕ времени предыдущего — через ROW_NUMBER() в подзапросе,
      который выбирает первое подходящее событие.

   3) remove_from_cart в воронке не участвует: это не шаг к покупке,
      а откат назад. Он анализируется отдельно (запрос 2.4).
   ========================================================================== */

SET TIME ZONE 'UTC';


/* -----------------------------------------------------------------------------
   Запрос 2.1. Основная воронка: micro- и macro-конверсия.
-------------------------------------------------------------------------- */
WITH session_events AS (
    -- Оставляем только события воронки и сессии с валидным идентификатором.
    -- Строки с user_session IS NULL отбрасываем: без идентификатора визита
    -- восстановить последовательность действий невозможно.
    SELECT
        user_session,
        event_type,
        event_time
    FROM events
    WHERE event_type IN ('view', 'cart', 'purchase')
      AND user_session IS NOT NULL
),

step_1_view AS (
    -- Шаг 1: момент первого просмотра товара в сессии — точка входа в воронку
    SELECT
        user_session,
        MIN(event_time) AS viewed_at
    FROM session_events
    WHERE event_type = 'view'
    GROUP BY user_session
),

step_2_cart AS (
    -- Шаг 2: первое добавление в корзину, произошедшее СТРОГО ПОСЛЕ просмотра.
    -- ROW_NUMBER() нумерует все подходящие события внутри сессии по времени,
    -- фильтр rn = 1 оставляет самое раннее из них.
    SELECT
        user_session,
        event_time AS carted_at
    FROM (
        SELECT
            se.user_session,
            se.event_time,
            ROW_NUMBER() OVER (
                PARTITION BY se.user_session
                ORDER BY se.event_time
            ) AS rn
        FROM session_events AS se
        INNER JOIN step_1_view AS v
            ON v.user_session = se.user_session
        WHERE se.event_type = 'cart'
          AND se.event_time > v.viewed_at
    ) AS ranked_cart
    WHERE rn = 1
),

step_3_purchase AS (
    -- Шаг 3: первая покупка, совершённая СТРОГО ПОСЛЕ добавления в корзину.
    -- JOIN именно со step_2_cart, а не со step_1_view — так гарантируется,
    -- что сессия прошла все предыдущие шаги, и воронка остаётся монотонной
    -- (каждый следующий шаг — подмножество предыдущего).
    SELECT
        user_session,
        event_time AS purchased_at
    FROM (
        SELECT
            se.user_session,
            se.event_time,
            ROW_NUMBER() OVER (
                PARTITION BY se.user_session
                ORDER BY se.event_time
            ) AS rn
        FROM session_events AS se
        INNER JOIN step_2_cart AS c
            ON c.user_session = se.user_session
        WHERE se.event_type = 'purchase'
          AND se.event_time > c.carted_at
    ) AS ranked_purchase
    WHERE rn = 1
),

funnel_totals AS (
    -- Сводим количество сессий на каждом шаге в одну строку
    SELECT
        (SELECT COUNT(*) FROM step_1_view)     AS sessions_view,
        (SELECT COUNT(*) FROM step_2_cart)     AS sessions_cart,
        (SELECT COUNT(*) FROM step_3_purchase) AS sessions_purchase
),

funnel_steps AS (
    -- Разворачиваем «широкую» строку в «длинный» формат:
    -- один шаг воронки = одна строка. Это позволяет посчитать конверсии
    -- оконными функциями вместо ручного деления колонок друг на друга.
    SELECT 1 AS step_no, 'Просмотр товара (View)'      AS step_name, sessions_view     AS sessions FROM funnel_totals
    UNION ALL
    SELECT 2,            'Добавление в корзину (Cart)',                sessions_cart              FROM funnel_totals
    UNION ALL
    SELECT 3,            'Покупка (Purchase)',                         sessions_purchase          FROM funnel_totals
)

-- Итоговая воронка с двумя типами конверсии:
--   micro  — переход с предыдущего шага (LAG);
--   macro  — сквозная конверсия от вершины воронки (FIRST_VALUE).
SELECT
    step_no,
    step_name,
    sessions,

    -- Micro-conversion: доля сессий, перешедших с предыдущего шага
    ROUND(
        100.0 * sessions / NULLIF(LAG(sessions) OVER (ORDER BY step_no), 0),
        2
    ) AS micro_conversion_pct,

    -- Macro-conversion: доля сессий от самого первого шага воронки
    ROUND(
        100.0 * sessions / NULLIF(FIRST_VALUE(sessions) OVER (ORDER BY step_no), 0),
        2
    ) AS macro_conversion_pct,

    -- Абсолютные потери на переходе — где именно «течёт» воронка
    LAG(sessions) OVER (ORDER BY step_no) - sessions AS sessions_lost,

    ROUND(
        100.0 * (LAG(sessions) OVER (ORDER BY step_no) - sessions)
              / NULLIF(LAG(sessions) OVER (ORDER BY step_no), 0),
        2
    ) AS drop_off_pct
FROM funnel_steps
ORDER BY step_no;


/* -----------------------------------------------------------------------------
   Запрос 2.2. Динамика воронки по месяцам.

   Одна усреднённая воронка скрывает тренды: конверсия могла падать весь
   период, но среднее значение этого не покажет. Здесь та же логика шагов,
   но с разбивкой по месяцу входа в воронку.
-------------------------------------------------------------------------- */
WITH session_events AS (
    SELECT
        user_session,
        event_type,
        event_time
    FROM events
    WHERE event_type IN ('view', 'cart', 'purchase')
      AND user_session IS NOT NULL
),

step_1_view AS (
    SELECT
        user_session,
        MIN(event_time) AS viewed_at
    FROM session_events
    WHERE event_type = 'view'
    GROUP BY user_session
),

step_2_cart AS (
    SELECT
        user_session,
        event_time AS carted_at
    FROM (
        SELECT
            se.user_session,
            se.event_time,
            ROW_NUMBER() OVER (
                PARTITION BY se.user_session
                ORDER BY se.event_time
            ) AS rn
        FROM session_events AS se
        INNER JOIN step_1_view AS v
            ON v.user_session = se.user_session
        WHERE se.event_type = 'cart'
          AND se.event_time > v.viewed_at
    ) AS ranked_cart
    WHERE rn = 1
),

step_3_purchase AS (
    SELECT
        user_session,
        event_time AS purchased_at
    FROM (
        SELECT
            se.user_session,
            se.event_time,
            ROW_NUMBER() OVER (
                PARTITION BY se.user_session
                ORDER BY se.event_time
            ) AS rn
        FROM session_events AS se
        INNER JOIN step_2_cart AS c
            ON c.user_session = se.user_session
        WHERE se.event_type = 'purchase'
          AND se.event_time > c.carted_at
    ) AS ranked_purchase
    WHERE rn = 1
)

-- Месяц определяется по времени ВХОДА в воронку (первый просмотр),
-- чтобы сессия целиком относилась к одному периоду.
SELECT
    DATE_TRUNC('month', v.viewed_at)::DATE      AS month,
    TO_CHAR(v.viewed_at, 'YYYY-MM')             AS month_label,

    COUNT(*)                                    AS sessions_view,
    COUNT(c.user_session)                       AS sessions_cart,
    COUNT(p.user_session)                       AS sessions_purchase,

    -- Конверсия шаг-в-шаг
    ROUND(100.0 * COUNT(c.user_session) / NULLIF(COUNT(*), 0), 2)                  AS cr_view_to_cart_pct,
    ROUND(100.0 * COUNT(p.user_session) / NULLIF(COUNT(c.user_session), 0), 2)     AS cr_cart_to_purchase_pct,

    -- Сквозная конверсия визита в покупку
    ROUND(100.0 * COUNT(p.user_session) / NULLIF(COUNT(*), 0), 2)                  AS cr_macro_pct
FROM step_1_view AS v
LEFT JOIN step_2_cart AS c
    ON c.user_session = v.user_session
LEFT JOIN step_3_purchase AS p
    ON p.user_session = v.user_session
GROUP BY
    DATE_TRUNC('month', v.viewed_at)::DATE,
    TO_CHAR(v.viewed_at, 'YYYY-MM')
ORDER BY month;


/* -----------------------------------------------------------------------------
   Запрос 2.3. Скорость прохождения воронки.

   Отвечает на вопрос «сколько времени пользователь думает на каждом шаге».
   Медиана важнее среднего: распределение времени сильно скошено вправо
   (единичные сессии длиной в часы задирают среднее), поэтому берём
   PERCENTILE_CONT, а не AVG.
-------------------------------------------------------------------------- */
WITH session_events AS (
    SELECT
        user_session,
        event_type,
        event_time
    FROM events
    WHERE event_type IN ('view', 'cart', 'purchase')
      AND user_session IS NOT NULL
),

step_1_view AS (
    SELECT
        user_session,
        MIN(event_time) AS viewed_at
    FROM session_events
    WHERE event_type = 'view'
    GROUP BY user_session
),

step_2_cart AS (
    SELECT
        user_session,
        event_time AS carted_at
    FROM (
        SELECT
            se.user_session,
            se.event_time,
            ROW_NUMBER() OVER (
                PARTITION BY se.user_session
                ORDER BY se.event_time
            ) AS rn
        FROM session_events AS se
        INNER JOIN step_1_view AS v
            ON v.user_session = se.user_session
        WHERE se.event_type = 'cart'
          AND se.event_time > v.viewed_at
    ) AS ranked_cart
    WHERE rn = 1
),

step_3_purchase AS (
    SELECT
        user_session,
        event_time AS purchased_at
    FROM (
        SELECT
            se.user_session,
            se.event_time,
            ROW_NUMBER() OVER (
                PARTITION BY se.user_session
                ORDER BY se.event_time
            ) AS rn
        FROM session_events AS se
        INNER JOIN step_2_cart AS c
            ON c.user_session = se.user_session
        WHERE se.event_type = 'purchase'
          AND se.event_time > c.carted_at
    ) AS ranked_purchase
    WHERE rn = 1
),

step_durations AS (
    -- Длительность каждого перехода в секундах
    SELECT
        v.user_session,
        EXTRACT(EPOCH FROM (c.carted_at    - v.viewed_at))::NUMERIC AS sec_view_to_cart,
        EXTRACT(EPOCH FROM (p.purchased_at - c.carted_at))::NUMERIC AS sec_cart_to_purchase,
        EXTRACT(EPOCH FROM (p.purchased_at - v.viewed_at))::NUMERIC AS sec_total
    FROM step_1_view AS v
    INNER JOIN step_2_cart AS c
        ON c.user_session = v.user_session
    LEFT JOIN step_3_purchase AS p
        ON p.user_session = v.user_session
)

SELECT
    COUNT(*)                          AS sessions_with_cart,
    COUNT(sec_cart_to_purchase)       AS sessions_with_purchase,

    -- View -> Cart
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sec_view_to_cart)::NUMERIC, 1) AS median_sec_view_to_cart,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY sec_view_to_cart)::NUMERIC, 1) AS p90_sec_view_to_cart,

    -- Cart -> Purchase
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sec_cart_to_purchase)::NUMERIC, 1) AS median_sec_cart_to_purchase,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY sec_cart_to_purchase)::NUMERIC, 1) AS p90_sec_cart_to_purchase,

    -- Полный путь View -> Purchase
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sec_total)::NUMERIC, 1) AS median_sec_total
FROM step_durations;


/* -----------------------------------------------------------------------------
   Запрос 2.4. Анализ брошенных корзин (Cart Abandonment).

   Отдельный срез: что происходит с сессиями, дошедшими до корзины,
   но не завершившимися покупкой. Здесь как раз задействуется
   remove_from_cart, исключённый из основной воронки.
-------------------------------------------------------------------------- */
WITH cart_sessions AS (
    -- Сессии, в которых был хотя бы один add-to-cart
    SELECT
        user_session,
        MIN(event_time) FILTER (WHERE event_type = 'cart')             AS carted_at,
        MIN(event_time) FILTER (WHERE event_type = 'purchase')         AS purchased_at,
        COUNT(*)        FILTER (WHERE event_type = 'remove_from_cart') AS removals,
        MAX(price)      FILTER (WHERE event_type = 'cart')             AS cart_price
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY user_session
    HAVING COUNT(*) FILTER (WHERE event_type = 'cart') > 0
),

classified AS (
    -- Классифицируем исход каждой корзины
    SELECT
        user_session,
        cart_price,
        CASE
            WHEN purchased_at IS NOT NULL AND purchased_at > carted_at THEN 'Оплачена'
            WHEN removals > 0                                          THEN 'Товар удалён из корзины'
            ELSE                                                            'Брошена без действий'
        END AS cart_outcome
    FROM cart_sessions
)

SELECT
    cart_outcome,
    COUNT(*)                                            AS sessions,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)  AS share_pct,
    ROUND(AVG(cart_price), 2)                           AS avg_cart_price
FROM classified
GROUP BY cart_outcome
ORDER BY sessions DESC;
