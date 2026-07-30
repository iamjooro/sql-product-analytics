SET TIME ZONE 'UTC';

-- 1. DAU & Moving Average
WITH daily_active_users AS (
    SELECT
        DATE_TRUNC('day', event_time)::DATE AS activity_date,
        COUNT(DISTINCT user_id)             AS dau
    FROM events
    GROUP BY 1
)
SELECT
    activity_date,
    dau,
    -- 7-дневное скользящее среднее для сглаживания недельной сезонности
    ROUND(
        AVG(dau) OVER (
            ORDER BY activity_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ),
        0
    ) AS dau_7d_moving_avg,
    EXTRACT(ISODOW FROM activity_date)::INT AS day_of_week,
    CASE
        WHEN EXTRACT(ISODOW FROM activity_date) IN (6, 7) THEN 'Выходной'
        ELSE 'Будний день'
    END AS day_type
FROM daily_active_users
ORDER BY activity_date;


-- 2. WAU & MoM Growth
WITH weekly_active_users AS (
    SELECT
        DATE_TRUNC('week', event_time)::DATE AS week_start,
        COUNT(DISTINCT user_id)              AS wau
    FROM events
    GROUP BY 1
)
SELECT
    week_start,
    EXTRACT(ISOYEAR FROM week_start)::INT AS iso_year,
    EXTRACT(WEEK     FROM week_start)::INT AS iso_week,
    wau,
    wau - LAG(wau) OVER (ORDER BY week_start) AS wau_diff,
    ROUND(
        100.0 * (wau - LAG(wau) OVER (ORDER BY week_start))
              / NULLIF(LAG(wau) OVER (ORDER BY week_start), 0),
        2
    ) AS wau_growth_pct
FROM weekly_active_users
ORDER BY week_start;


-- 3. MAU, Sticky Factor & Intensity
WITH daily_active_users AS (
    SELECT
        DATE_TRUNC('day', event_time)::DATE AS activity_date,
        COUNT(DISTINCT user_id)             AS dau
    FROM events
    GROUP BY 1
),

monthly_active_users AS (
    SELECT
        DATE_TRUNC('month', event_time)::DATE AS activity_month,
        COUNT(DISTINCT user_id)               AS mau,
        COUNT(DISTINCT user_session)          AS sessions,
        COUNT(*)                              AS events_total
    FROM events
    GROUP BY 1
),

avg_daily_per_month AS (
    SELECT
        DATE_TRUNC('month', activity_date)::DATE AS activity_month,
        ROUND(AVG(dau), 0)                       AS avg_dau,
        MIN(dau)                                 AS min_dau,
        MAX(dau)                                 AS max_dau,
        COUNT(*)                                 AS active_days
    FROM daily_active_users
    GROUP BY 1
)

SELECT
    m.activity_month,
    TO_CHAR(m.activity_month, 'YYYY-MM')                 AS month_label,
    m.mau,
    a.avg_dau,
    a.min_dau,
    a.max_dau,
    -- Sticky Factor (avg DAU / MAU)
    ROUND(100.0 * a.avg_dau / NULLIF(m.mau, 0), 2)       AS sticky_factor_pct,
    -- Метрики активности на юзера
    ROUND(1.0 * m.sessions     / NULLIF(m.mau, 0), 2)    AS sessions_per_user,
    ROUND(1.0 * m.events_total / NULLIF(m.mau, 0), 2)    AS events_per_user,
    -- Динамика MAU MoM
    m.mau - LAG(m.mau) OVER (ORDER BY m.activity_month)  AS mau_diff,
    ROUND(
        100.0 * (m.mau - LAG(m.mau) OVER (ORDER BY m.activity_month))
              / NULLIF(LAG(m.mau) OVER (ORDER BY m.activity_month), 0),
        2
    ) AS mau_growth_pct
FROM monthly_active_users AS m
JOIN avg_daily_per_month AS a 
    ON a.activity_month = m.activity_month
ORDER BY m.activity_month;