"""
Генератор синтетических данных в схеме датасета

Зачем нужен: позволяет поднять проект и прогнать все SQL-запросы,
не дожидаясь скачивания реального датасета с Kaggle.

Данные генерируются с реалистичными свойствами:
  воронка с затухающей конверсией;
 когортное удержание с экспоненциальным затуханием;
  недельная сезонность активности;
 приток новых пользователей каждый месяц.

Использование:
    python scripts/generate_sample_data.py --events 200000 --out data/events.csv
"""

import argparse
import csv
import random
import uuid
from datetime import datetime, timedelta

START_DATE = datetime(2020, 4, 1)  
N_MONTHS = 8

P_VIEW_TO_CART = 0.28               
P_CART_TO_PURCHASE = 0.34           
P_REMOVE_FROM_CART = 0.18           

RETENTION_BASE = 0.42             
RETENTION_DECAY = 0.62            

CATEGORIES = [
    ("electronics.smartphone", ["samsung", "apple", "xiaomi", "huawei"]),
    ("electronics.audio.headphone", ["sony", "jbl", "apple"]),
    ("computers.notebook", ["lenovo", "asus", "hp", "apple"]),
    ("appliances.kitchen.refrigerator", ["lg", "bosch", "samsung"]),
    ("electronics.video.tv", ["lg", "samsung", "sony"]),
    ("apparel.shoes", [None, "nike", "adidas"]), 
]


def month_start(base: datetime, offset: int) -> datetime:
    """Возвращает первое число месяца, сдвинутого на `offset` месяцев от `base`."""
    year = base.year + (base.month - 1 + offset) // 12
    month = (base.month - 1 + offset) % 12 + 1
    return datetime(year, month, 1)


def random_time_in_month(rng: random.Random, m_start: datetime) -> datetime:
    """Случайный момент внутри месяца с недельной и суточной сезонностью."""
    m_end = month_start(m_start, 1)
    days_in_month = (m_end - m_start).days

    for _ in range(10):
        day = rng.randrange(days_in_month)
        candidate = m_start + timedelta(days=day)
        weight = 0.6 if candidate.weekday() >= 5 else 1.0
        if rng.random() < weight:
            break

    hour = min(23, max(0, int(rng.gauss(15, 4))))
    return candidate + timedelta(
        hours=hour, minutes=rng.randrange(60), seconds=rng.randrange(60)
    )


def build_session(rng: random.Random, user_id: int, session_start: datetime) -> list:
    """
    Генерирует список событий одной сессии, соблюдая хронологический порядок
    шагов воронки: view -> cart -> remove_from_cart -> purchase.
    """
    events = []
    session_id = str(uuid.uuid4())
    category_code, brands = rng.choice(CATEGORIES)
    brand = rng.choice(brands)
    product_id = rng.randrange(1_000_000, 1_100_000)
    category_id = rng.randrange(2_000_000_000, 2_000_000_050)
    price = round(rng.uniform(15, 1800), 2)

    t = session_start

    for _ in range(rng.randint(1, 4)):
        events.append((t, "view", product_id, category_id, category_code,
                       brand, price, user_id, session_id))
        t += timedelta(seconds=rng.randrange(20, 400))

    if rng.random() < P_VIEW_TO_CART:
        events.append((t, "cart", product_id, category_id, category_code,
                       brand, price, user_id, session_id))
        t += timedelta(seconds=rng.randrange(30, 900))

        if rng.random() < P_REMOVE_FROM_CART:
            events.append((t, "remove_from_cart", product_id, category_id,
                           category_code, brand, price, user_id, session_id))
            t += timedelta(seconds=rng.randrange(30, 600))

        if rng.random() < P_CART_TO_PURCHASE:
            events.append((t, "purchase", product_id, category_id, category_code,
                           brand, price, user_id, session_id))

    return events


def generate(target_events: int, seed: int) -> list:
    """Собирает полный лог событий за N_MONTHS месяцев."""
    rng = random.Random(seed)
    rows = []
    next_user_id = 500_000_000

    monthly_new_users = [
        int(1400 * (1 + 0.12 * i) * rng.uniform(0.85, 1.15)) for i in range(N_MONTHS)
    ]

    for cohort_idx, n_new in enumerate(monthly_new_users):
        cohort_start = month_start(START_DATE, cohort_idx)

        for _ in range(n_new):
            user_id = next_user_id
            next_user_id += 1

            for _ in range(rng.randint(1, 3)):
                rows.extend(
                    build_session(rng, user_id, random_time_in_month(rng, cohort_start))
                )

            p_return = RETENTION_BASE
            for offset in range(1, N_MONTHS - cohort_idx):
                if rng.random() >= p_return:
                    p_return *= RETENTION_DECAY
                    continue
                active_month = month_start(START_DATE, cohort_idx + offset)
                for _ in range(rng.randint(1, 2)):
                    rows.extend(
                        build_session(rng, user_id, random_time_in_month(rng, active_month))
                    )
                p_return *= RETENTION_DECAY

            if len(rows) >= target_events:
                break
        if len(rows) >= target_events:
            break

    rows.sort(key=lambda r: r[0])
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events", type=int, default=200_000,
                        help="примерное число событий (по умолчанию 200000)")
    parser.add_argument("--out", default="data/events.csv", help="путь к выходному CSV")
    parser.add_argument("--seed", type=int, default=42, help="seed для воспроизводимости")
    args = parser.parse_args()

    rows = generate(args.events, args.seed)

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "event_time", "event_type", "product_id", "category_id",
            "category_code", "brand", "price", "user_id", "user_session",
        ])
        for r in rows:
            writer.writerow([
                r[0].strftime("%Y-%m-%d %H:%M:%S UTC"),
                r[1], r[2], r[3],
                r[4] or "",          
                r[5] or "",
                r[6], r[7], r[8],
            ])

    users = len({r[7] for r in rows})
    print(f"Сгенерировано событий: {len(rows):,}")
    print(f"Уникальных пользователей: {users:,}")
    print(f"Период: {rows[0][0].date()} — {rows[-1][0].date()}")
    print(f"Файл сохранён: {args.out}")


if __name__ == "__main__":
    main()
