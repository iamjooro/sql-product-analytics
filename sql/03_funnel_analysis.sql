SET TIME ZONE 'UTC';

-- 1. ОСНОВНАЯ ВОРОНКА (Micro & Macro CR)
-- Единица анализа - сессия. Шаги строго хронологичны: View -> Cart -> Purchase
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
    GROUP BY 1
),

step_2_cart AS (
    -- Первое добавление в корзину строго после просмотра
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
        JOIN step_1_view AS v ON v.user_session = se.user_session
        WHERE se.event_type = 'cart'
          AND se.event_time > v.viewed_at
    ) AS ranked
    WHERE rn = 1
),

step_3_purchase AS (
    -- Первая покупка строго после корзины
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
        JOIN step_2_cart AS c ON c.user_session = se.user_session
        WHERE se.event_type = 'purchase'
          AND se.event_time > c.carted_at
    ) AS ranked
    WHERE rn = 1
),

funnel_totals AS (
    SELECT
        (SELECT COUNT(*) FROM step_1_view)     AS sessions_view,
        (SELECT COUNT(*) FROM step_2_cart)     AS sessions_cart,
        (SELECT COUNT(*) FROM step_3_purchase) AS sessions_purchase
),

funnel_steps AS (
    SELECT 1 AS step_no, 'View'     AS step_name, sessions_view     AS sessions FROM funnel_totals
    UNION ALL
    SELECT 2,            'Cart',                  sessions_cart                 FROM funnel_totals
    UNION ALL
    SELECT 3,            'Purchase',              sessions_purchase             FROM funnel_totals
)

SELECT
    step_no,
    step_name,
    sessions,
    -- Micro CR (переход с предыдущего шага)
    ROUND(
        100.0 * sessions / NULLIF(LAG(sessions) OVER (ORDER BY step_no), 0),
        2
    ) AS micro_cr_pct,
    -- Macro CR (сквозная конверсия от первого шага)
    ROUND(
        100.0 * sessions / NULLIF(FIRST_VALUE(sessions) OVER (ORDER BY step_no), 0),
        2
    ) AS macro_cr_pct,
    -- Потери на этапе
    LAG(sessions) OVER (ORDER BY step_no) - sessions AS sessions_lost,
    ROUND(
        100.0 * (LAG(sessions) OVER (ORDER BY step_no) - sessions)
              / NULLIF(LAG(sessions) OVER (ORDER BY step_no), 0),
        2
    ) AS drop_off_pct
FROM funnel_steps
ORDER BY step_no;


-- 2. ДИНАМИКА ВОРОНКИ ПО МЕСЯЦАМ
-- Месяц определяется по дате первого просмотра (входа в воронку)
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
    GROUP BY 1
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
        JOIN step_1_view AS v ON v.user_session = se.user_session
        WHERE se.event_type = 'cart'
          AND se.event_time > v.viewed_at
    ) AS ranked
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
        JOIN step_2_cart AS c ON c.user_session = se.user_session
        WHERE se.event_type = 'purchase'
          AND se.event_time > c.carted_at
    ) AS ranked
    WHERE rn = 1
)

SELECT
    DATE_TRUNC('month', v.viewed_at)::DATE                          AS month,
    TO_CHAR(v.viewed_at, 'YYYY-MM')                                 AS month_label,
    COUNT(*)                                                        AS sessions_view,
    COUNT(c.user_session)                                           AS sessions_cart,
    COUNT(p.user_session)                                           AS sessions_purchase,
    ROUND(100.0 * COUNT(c.user_session) / NULLIF(COUNT(*), 0), 2)  AS cr_view_to_cart_pct,
    ROUND(100.0 * COUNT(p.user_session) / NULLIF(COUNT(c.user_session), 0), 2) AS cr_cart_to_purchase_pct,
    ROUND(100.0 * COUNT(p.user_session) / NULLIF(COUNT(*), 0), 2)  AS cr_macro_pct
FROM step_1_view AS v
LEFT JOIN step_2_cart AS c ON c.user_session = v.user_session
LEFT JOIN step_3_purchase AS p ON p.user_session = v.user_session
GROUP BY 1, 2
ORDER BY month;


-- 3. ВРЕМЯ ПРОХОЖДЕНИЯ ШАГОВ 
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
    GROUP BY 1
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
        JOIN step_1_view AS v ON v.user_session = se.user_session
        WHERE se.event_type = 'cart'
          AND se.event_time > v.viewed_at
    ) AS ranked
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
        JOIN step_2_cart AS c ON c.user_session = se.user_session
        WHERE se.event_type = 'purchase'
          AND se.event_time > c.carted_at
    ) AS ranked
    WHERE rn = 1
),

step_durations AS (
    SELECT
        v.user_session,
        EXTRACT(EPOCH FROM (c.carted_at    - v.viewed_at))::NUMERIC AS sec_view_to_cart,
        EXTRACT(EPOCH FROM (p.purchased_at - c.carted_at))::NUMERIC AS sec_cart_to_purchase,
        EXTRACT(EPOCH FROM (p.purchased_at - v.viewed_at))::NUMERIC AS sec_total
    FROM step_1_view AS v
    JOIN step_2_cart AS c ON c.user_session = v.user_session
    LEFT JOIN step_3_purchase AS p ON p.user_session = v.user_session
)

SELECT
    COUNT(*)                    AS sessions_with_cart,
    COUNT(sec_cart_to_purchase) AS sessions_with_purchase,
    -- View -> Cart
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sec_view_to_cart)::NUMERIC, 1) AS median_sec_view_to_cart,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY sec_view_to_cart)::NUMERIC, 1) AS p90_sec_view_to_cart,
    -- Cart -> Purchase
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sec_cart_to_purchase)::NUMERIC, 1) AS median_sec_cart_to_purchase,
    ROUND(PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY sec_cart_to_purchase)::NUMERIC, 1) AS p90_sec_cart_to_purchase,
    -- View -> Purchase
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sec_total)::NUMERIC, 1) AS median_sec_total
FROM step_durations;


-- 4. АНАЛИЗ БРОШЕННЫХ КОРЗИН (Cart Abandonment)
WITH cart_sessions AS (
    SELECT
        user_session,
        MIN(event_time) FILTER (WHERE event_type = 'cart')             AS carted_at,
        MIN(event_time) FILTER (WHERE event_type = 'purchase')         AS purchased_at,
        COUNT(*)        FILTER (WHERE event_type = 'remove_from_cart') AS removals,
        MAX(price)      FILTER (WHERE event_type = 'cart')             AS cart_price
    FROM events
    WHERE user_session IS NOT NULL
    GROUP BY 1
    HAVING COUNT(*) FILTER (WHERE event_type = 'cart') > 0
),

classified AS (
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
GROUP BY 1
ORDER BY sessions DESC;