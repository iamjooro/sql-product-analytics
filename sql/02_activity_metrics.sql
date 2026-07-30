/* =============================================================================
   БЛОК 1. Базовые метрики активности: DAU, WAU, MAU, Sticky Factor
   -----------------------------------------------------------------------------
   Активностью считается любое событие пользователя (view / cart /
   remove_from_cart / purchase) — то есть меряем вовлечённость в продукт,
   а не только покупательскую активность.

   Важное методологическое замечание: MAU НЕ равен сумме DAU за месяц.
   Один пользователь, заходивший 10 дней подряд, даст 10 в сумму DAU,
   но только 1 в MAU. Поэтому каждая метрика считается через
   COUNT(DISTINCT user_id) на своём уровне агрегации, а не суммированием
   уровня ниже.
   ========================================================================== */

SET TIME ZONE 'UTC';


/* -----------------------------------------------------------------------------
   Запрос 1.1. DAU — Daily Active Users.

   Дополнительно считаем скользящее среднее за 7 дней: дневная активность
   сильно «шумит» из-за недельной сезонности, и без сглаживания тренд
   на графике не читается.
-------------------------------------------------------------------------- */
WITH daily_active_users AS (
    -- Уникальные пользователи в разрезе календарных суток
    SELECT
        DATE_TRUNC('day', event_time)::DATE AS activity_date,
        COUNT(DISTINCT user_id)             AS dau
    FROM events
    GROUP BY DATE_TRUNC('day', event_time)::DATE
)

-- Итоговая витрина: DAU, сглаженный тренд и день недели для анализа сезонности
SELECT
    activity_date,
    dau,

    -- Скользящее среднее за текущий и 6 предыдущих дней
    ROUND(
        AVG(dau) OVER (
            ORDER BY activity_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ),
        0
    ) AS dau_7d_moving_avg,

    -- ISO-номер дня недели: 1 = понедельник, 7 = воскресенье
    EXTRACT(ISODOW FROM activity_date)::INT AS day_of_week,

    CASE
        WHEN EXTRACT(ISODOW FROM activity_date) IN (6, 7) THEN 'Выходной'
        ELSE 'Будний день'
    END AS day_type
FROM daily_active_users
ORDER BY activity_date;


/* -----------------------------------------------------------------------------
   Запрос 1.2. WAU — Weekly Active Users.

   Неделя определяется по стандарту ISO 8601 (начинается с понедельника),
   что даёт корректную стыковку недель на границах месяцев и годов.
-------------------------------------------------------------------------- */
WITH weekly_active_users AS (
    -- Уникальные пользователи в разрезе календарных недель
    SELECT
        DATE_TRUNC('week', event_time)::DATE AS week_start,
        COUNT(DISTINCT user_id)              AS wau
    FROM events
    GROUP BY DATE_TRUNC('week', event_time)::DATE
)

-- Добавляем неделя-к-неделе прирост через оконную функцию LAG
SELECT
    week_start,
    EXTRACT(ISOYEAR FROM week_start)::INT AS iso_year,
    EXTRACT(WEEK    FROM week_start)::INT AS iso_week,
    wau,

    -- Абсолютное и относительное изменение к предыдущей неделе
    wau - LAG(wau) OVER (ORDER BY week_start) AS wau_diff,
    ROUND(
        100.0 * (wau - LAG(wau) OVER (ORDER BY week_start))
              / NULLIF(LAG(wau) OVER (ORDER BY week_start), 0),
        2
    ) AS wau_growth_pct
FROM weekly_active_users
ORDER BY week_start;


/* -----------------------------------------------------------------------------
   Запрос 1.3. MAU и Sticky Factor — главная витрина блока.

   Sticky Factor = средний DAU за месяц / MAU этого месяца.
   Метрика отвечает на вопрос: «какую долю своей месячной аудитории продукт
   удерживает в среднем в каждый отдельный день?». Интерпретация:
     ~20%  и выше — сильная вовлечённость (пользователь заходит ~6 дней в месяц);
     10–20%       — нормально для e-commerce с редким циклом покупки;
     ниже 10%     — продукт используют эпизодически, «от случая к случаю».
-------------------------------------------------------------------------- */
WITH daily_active_users AS (
    -- Уровень 1: уникальные пользователи по дням
    SELECT
        DATE_TRUNC('day', event_time)::DATE AS activity_date,
        COUNT(DISTINCT user_id)             AS dau
    FROM events
    GROUP BY DATE_TRUNC('day', event_time)::DATE
),

monthly_active_users AS (
    -- Уровень 2: уникальные пользователи по месяцам.
    -- Считается отдельным проходом по events, а не агрегацией DAU,
    -- потому что один пользователь активен в нескольких днях месяца.
    SELECT
        DATE_TRUNC('month', event_time)::DATE AS activity_month,
        COUNT(DISTINCT user_id)               AS mau,
        COUNT(DISTINCT user_session)          AS sessions,
        COUNT(*)                              AS events_total
    FROM events
    GROUP BY DATE_TRUNC('month', event_time)::DATE
),

avg_daily_per_month AS (
    -- Средний, минимальный и максимальный DAU внутри каждого месяца
    SELECT
        DATE_TRUNC('month', activity_date)::DATE AS activity_month,
        ROUND(AVG(dau), 0)                       AS avg_dau,
        MIN(dau)                                 AS min_dau,
        MAX(dau)                                 AS max_dau,
        COUNT(*)                                 AS active_days
    FROM daily_active_users
    GROUP BY DATE_TRUNC('month', activity_date)::DATE
)

-- Финальная витрина: объём аудитории, вовлечённость и динамика роста
SELECT
    m.activity_month,
    TO_CHAR(m.activity_month, 'YYYY-MM')                AS month_label,

    m.mau,
    a.avg_dau,
    a.min_dau,
    a.max_dau,

    -- Sticky Factor: доля месячной аудитории, активная в среднедневном срезе
    ROUND(100.0 * a.avg_dau / NULLIF(m.mau, 0), 2)      AS sticky_factor_pct,

    -- Интенсивность использования продукта
    ROUND(1.0 * m.sessions     / NULLIF(m.mau, 0), 2)   AS sessions_per_user,
    ROUND(1.0 * m.events_total / NULLIF(m.mau, 0), 2)   AS events_per_user,

    -- Динамика месяц к месяцу (Month-over-Month)
    m.mau - LAG(m.mau) OVER (ORDER BY m.activity_month) AS mau_diff,
    ROUND(
        100.0 * (m.mau - LAG(m.mau) OVER (ORDER BY m.activity_month))
              / NULLIF(LAG(m.mau) OVER (ORDER BY m.activity_month), 0),
        2
    ) AS mau_growth_pct
FROM monthly_active_users AS m
INNER JOIN avg_daily_per_month AS a
    ON a.activity_month = m.activity_month
ORDER BY m.activity_month;
