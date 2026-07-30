/*
   БЛОК 3. Когортный анализ удержания 
*/

SET TIME ZONE 'UTC';


/*
   3.1. Pivot Retention Rate (%) - сводная таблица M0..M6
*/
WITH 
user_cohorts AS (
    -- Определяем когорту для каждого юзера
    SELECT 
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_activity AS (
    -- Считаем, на какой месяц (M0, M1, M2...)
    SELECT DISTINCT
        uc.cohort_month,
        e.user_id,
        -- Быстрый способ посчитать разницу в месяцах:
        (EXTRACT(YEAR FROM e.event_time) - EXTRACT(YEAR FROM uc.cohort_month)) * 12 
        + (EXTRACT(MONTH FROM e.event_time) - EXTRACT(MONTH FROM uc.cohort_month)) AS month_num
    FROM events e
    JOIN user_cohorts uc ON uc.user_id = e.user_id
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS total_users 
    FROM user_cohorts 
    GROUP BY cohort_month
)

SELECT 
    cs.cohort_month,
    TO_CHAR(cs.cohort_month, 'YYYY-MM') AS cohort,
    cs.total_users,

    -- Разворачиваем M0..M6 в столбцы. 
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 0) / cs.total_users, 1) AS m0,
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 1) / cs.total_users, 1) AS m1,
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 2) / cs.total_users, 1) AS m2,
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 3) / cs.total_users, 1) AS m3,
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 4) / cs.total_users, 1) AS m4,
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 5) / cs.total_users, 1) AS m5,
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) FILTER (WHERE ua.month_num = 6) / cs.total_users, 1) AS m6
FROM cohort_sizes cs
LEFT JOIN user_activity ua ON ua.cohort_month = cs.cohort_month
GROUP BY cs.cohort_month, cs.total_users
ORDER BY cs.cohort_month;


/* 
   3.2. Retention в абсолютaх (голые цифры)
*/
WITH 
user_cohorts AS (
    SELECT 
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_activity AS (
    SELECT DISTINCT
        uc.cohort_month,
        e.user_id,
        (EXTRACT(YEAR FROM e.event_time) - EXTRACT(YEAR FROM uc.cohort_month)) * 12 
        + (EXTRACT(MONTH FROM e.event_time) - EXTRACT(MONTH FROM uc.cohort_month)) AS month_num
    FROM events e
    JOIN user_cohorts uc ON uc.user_id = e.user_id
)

SELECT 
    cohort_month,
    TO_CHAR(cohort_month, 'YYYY-MM') AS cohort,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 0) AS m0_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 1) AS m1_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 2) AS m2_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 3) AS m3_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 4) AS m4_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 5) AS m5_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_num = 6) AS m6_users
FROM user_activity
GROUP BY cohort_month
ORDER BY cohort_month;


/*
   3.3. Long-формат 
   
   Считает сразу два типа удержания:
     Classic: был ли активен конкретно в месяце N.
     Rolling: заходил ли в месяце N ИЛИ в любой из последующих.
*/
WITH 
user_cohorts AS (
    SELECT 
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_activity AS (
    SELECT 
        uc.cohort_month,
        e.user_id,
        (EXTRACT(YEAR FROM e.event_time) - EXTRACT(YEAR FROM uc.cohort_month)) * 12 
        + (EXTRACT(MONTH FROM e.event_time) - EXTRACT(MONTH FROM uc.cohort_month)) AS month_num
    FROM events e
    JOIN user_cohorts uc ON uc.user_id = e.user_id
    GROUP BY 1, 2, 3
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS total_users 
    FROM user_cohorts 
    GROUP BY cohort_month
),

-- Для Rolling Retention фиксируем последний месяц активности юзера
user_lifespan AS (
    SELECT 
        cohort_month,
        user_id,
        MAX(month_num) AS last_active_month
    FROM user_activity
    GROUP BY cohort_month, user_id
),

monthly_summary AS (
    SELECT 
        cohort_month,
        month_num,
        COUNT(DISTINCT user_id) AS active_users
    FROM user_activity
    GROUP BY cohort_month, month_num
)

SELECT 
    cs.cohort_month,
    TO_CHAR(cs.cohort_month, 'YYYY-MM') AS cohort,
    cs.total_users,
    ms.month_num,
    ms.active_users,
    
    -- Classic Retention (%)
    ROUND(100.0 * ms.active_users / cs.total_users, 1) AS retention_pct,

    -- Rolling Retention (%): сколько людей вернулись в M_N или ПОЗЖЕ
    ROUND(100.0 * (
        SELECT COUNT(ul.user_id)
        FROM user_lifespan ul
        WHERE ul.cohort_month = ms.cohort_month
          AND ul.last_active_month >= ms.month_num
    ) / cs.total_users, 1) AS rolling_retention_pct

FROM cohort_sizes cs
JOIN monthly_summary ms ON ms.cohort_month = cs.cohort_month
ORDER BY cs.cohort_month, ms.month_num;


/*
   3.4. Итоговая усреднённая кривая Retention
   Схлопывает матрицу в одну общую линию удержания.
*/
WITH 
user_cohorts AS (
    SELECT 
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_activity AS (
    SELECT 
        uc.cohort_month,
        e.user_id,
        (EXTRACT(YEAR FROM e.event_time) - EXTRACT(YEAR FROM uc.cohort_month)) * 12 
        + (EXTRACT(MONTH FROM e.event_time) - EXTRACT(MONTH FROM uc.cohort_month)) AS month_num
    FROM events e
    JOIN user_cohorts uc ON uc.user_id = e.user_id
    GROUP BY 1, 2, 3
),

cohort_sizes AS (
    SELECT cohort_month, COUNT(*) AS total_users 
    FROM user_cohorts 
    GROUP BY cohort_month
),

-- Максимальный доступный месяц в датасете
dataset_max_month AS (
    SELECT MAX(DATE_TRUNC('month', event_time)::DATE) AS max_month 
    FROM events
),

-- Отсекаем когорты, которые физически еще не дожили до проверяемого месяца,
-- чтобы они не портили формулу нулевым возвратом
matured_cohorts AS (
    SELECT 
        cs.cohort_month,
        cs.total_users,
        (EXTRACT(YEAR FROM dm.max_month) - EXTRACT(YEAR FROM cs.cohort_month)) * 12 
        + (EXTRACT(MONTH FROM dm.max_month) - EXTRACT(MONTH FROM cs.cohort_month)) AS max_observable_month
    FROM cohort_sizes cs
    CROSS JOIN dataset_max_month dm
)

SELECT 
    ua.month_num,
    COUNT(DISTINCT ua.cohort_month) AS cohorts_count,
    COUNT(DISTINCT ua.user_id) AS active_users,
    SUM(mc.total_users) AS total_eligible_users,
    
    ROUND(100.0 * COUNT(DISTINCT ua.user_id) / NULLIF(SUM(mc.total_users), 0), 1) AS avg_retention_pct
FROM user_activity ua
JOIN matured_cohorts mc 
  ON mc.cohort_month = ua.cohort_month
 AND mc.max_observable_month >= ua.month_num -- берем только созревшие когорты
GROUP BY ua.month_num
ORDER BY ua.month_num;