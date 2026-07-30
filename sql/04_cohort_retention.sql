/* =============================================================================
   БЛОК 3. Когортный анализ удержания (Retention Rate)
   -----------------------------------------------------------------------------
   Когорта — месяц первой активности пользователя (First Touch, MIN(event_time)).
   Пользователь попадает ровно в одну когорту навсегда и больше её не меняет.

   Retention Rate на месяц N = доля пользователей когорты, проявивших любую
   активность в N-м месяце после месяца регистрации.

   Как читать таблицу:
     * строка   — когорта (месяц прихода);
     * столбец  — «возраст» когорты в месяцах (M0, M1, M2, ...);
     * M0 всегда = 100% по определению (месяц прихода = месяц первой активности),
       он оставлен как контрольный столбец: любое значение ≠ 100 означает
       ошибку в логике запроса;
     * таблица треугольная — у молодых когорт просто ещё не наступили
       поздние месяцы жизни, там NULL (а не ноль! ноль означал бы, что все
       пользователи ушли, а NULL — что данных ещё нет).
   ========================================================================== */

SET TIME ZONE 'UTC';


/* -----------------------------------------------------------------------------
   Запрос 3.1. Retention Rate в процентах — основная сводная таблица.

   Столбцы M0..M6 захардкожены через CASE WHEN, потому что стандартный SQL
   не умеет динамически определять количество колонок. Если период данных
   длиннее — просто дописать блоки по образцу (или использовать запрос 3.3,
   который не зависит от длины периода).
-------------------------------------------------------------------------- */
WITH user_first_touch AS (
    -- Определяем когорту: месяц самого первого события пользователя
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_active_months AS (
    -- Все месяцы, в которых пользователь был активен.
    -- DISTINCT схлопывает множество событий одного месяца в одну строку:
    -- для retention важен сам факт возврата, а не его интенсивность.
    SELECT DISTINCT
        user_id,
        DATE_TRUNC('month', event_time)::DATE AS activity_month
    FROM events
    WHERE user_id IS NOT NULL
),

cohort_activity AS (
    -- Считаем «возраст» активности: сколько месяцев прошло от когорты.
    -- Разница вычисляется через год*12 + месяц, а не вычитанием дат:
    -- прямое вычитание дало бы интервал в днях, который из-за разной длины
    -- месяцев не переводится в номер месяца однозначно.
    SELECT
        uft.cohort_month,
        uam.user_id,
        (EXTRACT(YEAR  FROM uam.activity_month)::INT - EXTRACT(YEAR  FROM uft.cohort_month)::INT) * 12
      + (EXTRACT(MONTH FROM uam.activity_month)::INT - EXTRACT(MONTH FROM uft.cohort_month)::INT)
            AS month_number
    FROM user_active_months AS uam
    INNER JOIN user_first_touch AS uft
        ON uft.user_id = uam.user_id
),

cohort_size AS (
    -- Размер каждой когорты — знаменатель для расчёта процентов
    SELECT
        cohort_month,
        COUNT(*) AS cohort_users
    FROM user_first_touch
    GROUP BY cohort_month
),

retention_raw AS (
    -- Число вернувшихся пользователей в разрезе «когорта × месяц жизни»
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT user_id) AS active_users
    FROM cohort_activity
    GROUP BY
        cohort_month,
        month_number
)

-- Разворачиваем длинный формат в сводную таблицу: месяцы жизни -> столбцы
SELECT
    cs.cohort_month,
    TO_CHAR(cs.cohort_month, 'YYYY-MM') AS cohort_label,
    cs.cohort_users,

    -- M0 всегда 100%: контрольный столбец для проверки корректности логики
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 0 THEN rr.active_users END) / cs.cohort_users, 1) AS m0_pct,
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 1 THEN rr.active_users END) / cs.cohort_users, 1) AS m1_pct,
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 2 THEN rr.active_users END) / cs.cohort_users, 1) AS m2_pct,
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 3 THEN rr.active_users END) / cs.cohort_users, 1) AS m3_pct,
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 4 THEN rr.active_users END) / cs.cohort_users, 1) AS m4_pct,
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 5 THEN rr.active_users END) / cs.cohort_users, 1) AS m5_pct,
    ROUND(100.0 * MAX(CASE WHEN rr.month_number = 6 THEN rr.active_users END) / cs.cohort_users, 1) AS m6_pct
FROM cohort_size AS cs
LEFT JOIN retention_raw AS rr
    ON rr.cohort_month = cs.cohort_month
GROUP BY
    cs.cohort_month,
    cs.cohort_users
ORDER BY cs.cohort_month;


/* -----------------------------------------------------------------------------
   Запрос 3.2. То же самое в абсолютных числах.

   Проценты скрывают масштаб: 40% удержания у когорты из 50 человек и у
   когорты из 5000 — принципиально разные по значимости результаты.
   Эту таблицу удобно смотреть рядом с процентной.
-------------------------------------------------------------------------- */
WITH user_first_touch AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_active_months AS (
    SELECT DISTINCT
        user_id,
        DATE_TRUNC('month', event_time)::DATE AS activity_month
    FROM events
    WHERE user_id IS NOT NULL
),

cohort_activity AS (
    SELECT
        uft.cohort_month,
        uam.user_id,
        (EXTRACT(YEAR  FROM uam.activity_month)::INT - EXTRACT(YEAR  FROM uft.cohort_month)::INT) * 12
      + (EXTRACT(MONTH FROM uam.activity_month)::INT - EXTRACT(MONTH FROM uft.cohort_month)::INT)
            AS month_number
    FROM user_active_months AS uam
    INNER JOIN user_first_touch AS uft
        ON uft.user_id = uam.user_id
)

SELECT
    cohort_month,
    TO_CHAR(cohort_month, 'YYYY-MM')                                AS cohort_label,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 0)         AS m0_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 1)         AS m1_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 2)         AS m2_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 3)         AS m3_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 4)         AS m4_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 5)         AS m5_users,
    COUNT(DISTINCT user_id) FILTER (WHERE month_number = 6)         AS m6_users
FROM cohort_activity
GROUP BY cohort_month
ORDER BY cohort_month;


/* -----------------------------------------------------------------------------
   Запрос 3.3. Retention в «длинном» формате (tidy data).

   Не зависит от длины периода наблюдений — количество строк подстраивается
   под данные автоматически. Именно такой формат нужно отдавать в BI-системы
   (Tableau, Power BI, Metabase): они строят heatmap-матрицу сами,
   а захардкоженные столбцы из запроса 3.1 им только мешают.

   Дополнительно считается rolling retention — доля пользователей, вернувшихся
   в этот месяц ИЛИ позже. Классический (classic) retention отвечает на вопрос
   «был ли активен именно в N-м месяце», rolling — «не ушёл ли навсегда
   к N-му месяцу». Вторая метрика устойчивее к нерегулярному использованию,
   характерному для e-commerce.
-------------------------------------------------------------------------- */
WITH user_first_touch AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_active_months AS (
    SELECT DISTINCT
        user_id,
        DATE_TRUNC('month', event_time)::DATE AS activity_month
    FROM events
    WHERE user_id IS NOT NULL
),

cohort_activity AS (
    SELECT
        uft.cohort_month,
        uam.user_id,
        (EXTRACT(YEAR  FROM uam.activity_month)::INT - EXTRACT(YEAR  FROM uft.cohort_month)::INT) * 12
      + (EXTRACT(MONTH FROM uam.activity_month)::INT - EXTRACT(MONTH FROM uft.cohort_month)::INT)
            AS month_number
    FROM user_active_months AS uam
    INNER JOIN user_first_touch AS uft
        ON uft.user_id = uam.user_id
),

cohort_size AS (
    SELECT
        cohort_month,
        COUNT(*) AS cohort_users
    FROM user_first_touch
    GROUP BY cohort_month
),

retention_raw AS (
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT user_id) AS active_users
    FROM cohort_activity
    GROUP BY
        cohort_month,
        month_number
),

user_lifespan AS (
    -- Последний месяц жизни каждого пользователя: нужен для rolling retention.
    -- Считать rolling простым суммированием active_users по месяцам НЕЛЬЗЯ —
    -- пользователь, активный в M1 и M3, попал бы в сумму дважды.
    SELECT
        cohort_month,
        user_id,
        MAX(month_number) AS last_active_month
    FROM cohort_activity
    GROUP BY
        cohort_month,
        user_id
),

rolling_retention AS (
    -- Сколько уникальных пользователей когорты были активны в месяце N
    -- ИЛИ в любом более позднем месяце (то есть ещё не ушли окончательно)
    SELECT
        rr.cohort_month,
        rr.month_number,
        COUNT(ul.user_id) AS rolling_users
    FROM retention_raw AS rr
    LEFT JOIN user_lifespan AS ul
        ON ul.cohort_month = rr.cohort_month
       AND ul.last_active_month >= rr.month_number
    GROUP BY
        rr.cohort_month,
        rr.month_number
)

SELECT
    cs.cohort_month,
    TO_CHAR(cs.cohort_month, 'YYYY-MM')                        AS cohort_label,
    cs.cohort_users,
    rr.month_number,
    rr.active_users,

    -- Classic retention: пользователь активен именно в этом месяце
    ROUND(100.0 * rr.active_users / cs.cohort_users, 1)        AS retention_pct,

    -- Rolling retention: пользователь активен в этом месяце или позже
    ROUND(100.0 * rlr.rolling_users / cs.cohort_users, 1)      AS rolling_retention_pct
FROM cohort_size AS cs
INNER JOIN retention_raw AS rr
    ON rr.cohort_month = cs.cohort_month
INNER JOIN rolling_retention AS rlr
    ON rlr.cohort_month = rr.cohort_month
   AND rlr.month_number = rr.month_number
ORDER BY
    cs.cohort_month,
    rr.month_number;


/* -----------------------------------------------------------------------------
   Запрос 3.4. Средняя кривая удержания по всем когортам.

   Сводит треугольную матрицу к одной кривой — «средний профиль» продукта.
   Пригодится для README и для сравнения с бенчмарками индустрии.

   Важная деталь: усреднять проценты по когортам напрямую нельзя (когорты
   разного размера, маленькая когорта получила бы тот же вес, что большая).
   Поэтому считаем взвешенно: сумма вернувшихся / сумма размеров когорт.
-------------------------------------------------------------------------- */
WITH user_first_touch AS (
    SELECT
        user_id,
        DATE_TRUNC('month', MIN(event_time))::DATE AS cohort_month
    FROM events
    WHERE user_id IS NOT NULL
    GROUP BY user_id
),

user_active_months AS (
    SELECT DISTINCT
        user_id,
        DATE_TRUNC('month', event_time)::DATE AS activity_month
    FROM events
    WHERE user_id IS NOT NULL
),

cohort_activity AS (
    SELECT
        uft.cohort_month,
        uam.user_id,
        (EXTRACT(YEAR  FROM uam.activity_month)::INT - EXTRACT(YEAR  FROM uft.cohort_month)::INT) * 12
      + (EXTRACT(MONTH FROM uam.activity_month)::INT - EXTRACT(MONTH FROM uft.cohort_month)::INT)
            AS month_number
    FROM user_active_months AS uam
    INNER JOIN user_first_touch AS uft
        ON uft.user_id = uam.user_id
),

cohort_size AS (
    SELECT
        cohort_month,
        COUNT(*) AS cohort_users
    FROM user_first_touch
    GROUP BY cohort_month
),

data_bounds AS (
    -- Последний месяц, за который вообще есть данные
    SELECT MAX(DATE_TRUNC('month', event_time)::DATE) AS last_month
    FROM events
),

max_observed_month AS (
    -- Для каждой когорты — сколько месяцев жизни реально наблюдалось.
    -- Нужно, чтобы не занижать среднее: молодые когорты не должны попадать
    -- в расчёт удержания на тех месяцах, до которых они ещё не дожили.
    SELECT
        cs.cohort_month,
        cs.cohort_users,
        (EXTRACT(YEAR  FROM db.last_month)::INT - EXTRACT(YEAR  FROM cs.cohort_month)::INT) * 12
      + (EXTRACT(MONTH FROM db.last_month)::INT - EXTRACT(MONTH FROM cs.cohort_month)::INT)
            AS months_observed
    FROM cohort_size AS cs
    CROSS JOIN data_bounds AS db
),

retention_raw AS (
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT user_id) AS active_users
    FROM cohort_activity
    GROUP BY
        cohort_month,
        month_number
)

SELECT
    rr.month_number,
    COUNT(DISTINCT rr.cohort_month)                                     AS cohorts_in_calc,
    SUM(rr.active_users)                                                AS total_active_users,
    SUM(mo.cohort_users)                                                AS total_cohort_users,

    -- Взвешенное среднее удержание по всем когортам, дожившим до этого месяца
    ROUND(100.0 * SUM(rr.active_users) / NULLIF(SUM(mo.cohort_users), 0), 1) AS avg_retention_pct
FROM retention_raw AS rr
INNER JOIN max_observed_month AS mo
    ON mo.cohort_month = rr.cohort_month
   AND mo.months_observed >= rr.month_number   -- только «дожившие» когорты
GROUP BY rr.month_number
ORDER BY rr.month_number;
