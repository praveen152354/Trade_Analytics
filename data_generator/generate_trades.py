"""
Simulates trade messages arriving from upstream trading systems.

Each run produces a batch of trade records as a JSON-lines file, mimicking
a feed that would normally arrive from a trading venue / booking system.
A record can represent:
  - a brand new trade (version = 1)
  - an amendment to an existing trade (version > previous version, same trade_id)
  - a duplicate / replay (same version as an existing trade)
  - a stale/out-of-order message (version lower than an existing trade)
  - a trade already past its maturity date (to exercise the "expired" rule)

Output files are dropped into ./output/ as trades_<batch_ts>.jsonl and are
picked up by the ingestion step (Snowflake external/internal stage + COPY INTO).
"""

import argparse
import json
import random
import string
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

CURRENCIES = ["USD", "EUR", "GBP", "JPY", "CHF", "AUD"]
PRODUCT_TYPES = ["FX_SPOT", "FX_FORWARD", "IRS", "FX_OPTION", "BOND"]
COUNTERPARTIES = [
    "GOLDMAN_SACHS", "JP_MORGAN", "BARCLAYS", "DEUTSCHE_BANK",
    "CITI", "HSBC", "MORGAN_STANLEY", "UBS",
]
TRADERS = ["trader_" + c for c in string.ascii_lowercase[:8]]
BOOKS = ["RATES_BOOK_1", "RATES_BOOK_2", "FX_BOOK_1", "CREDIT_BOOK_1"]

OUTPUT_DIR = Path(__file__).parent / "output"


def random_maturity(days_min: int, days_max: int, reference_date=None) -> str:
    ref = reference_date or datetime.now(timezone.utc).date()
    d = ref + timedelta(days=random.randint(days_min, days_max))
    return d.isoformat()


def new_trade(trade_id: str, version: int, maturity_offset=(1, 730), event_dt=None) -> dict:
    # event_dt lets a backfill stamp a historical trade_date/event_timestamp
    # instead of "now" (used by generate_backfill.py). maturity_date is
    # computed relative to event_dt (when the trade was booked), not real
    # "now" -- so a trade backfilled to 25 days ago with a small maturity
    # offset can organically already be expired by today, same as it would
    # have been had it really been booked back then.
    now = event_dt or datetime.now(timezone.utc)
    return {
        "trade_id": trade_id,
        "version": version,
        "source_system": "MOCK_TRADE_FEED",
        "message_id": str(uuid.uuid4()),
        "event_timestamp": now.isoformat(),
        "trade_date": now.date().isoformat(),
        "maturity_date": random_maturity(*maturity_offset, reference_date=now.date()),
        "product_type": random.choice(PRODUCT_TYPES),
        "counterparty": random.choice(COUNTERPARTIES),
        "trader": random.choice(TRADERS),
        "book": random.choice(BOOKS),
        "currency": random.choice(CURRENCIES),
        "notional": round(random.uniform(100_000, 50_000_000), 2),
        "price": round(random.uniform(0.5, 150.0), 4),
        "status": "NEW",
    }


def generate_batch(num_trades: int, pct_amendments: float, pct_out_of_order: float,
                    pct_duplicates: float, pct_already_expired: float,
                    event_dt=None) -> list[dict]:
    """Builds one batch of trade messages, seeding it with realistic edge cases.
    event_dt, if given, backdates every record in the batch to that
    timestamp instead of "now" (see new_trade)."""
    records: list[dict] = []
    known_trades: dict[str, int] = {}  # trade_id -> highest version emitted so far

    for _ in range(num_trades):
        roll = random.random()

        if known_trades and roll < pct_amendments:
            trade_id = random.choice(list(known_trades.keys()))
            new_version = known_trades[trade_id] + 1
            known_trades[trade_id] = new_version
            rec = new_trade(trade_id, new_version, event_dt=event_dt)

        elif known_trades and roll < pct_amendments + pct_duplicates:
            trade_id = random.choice(list(known_trades.keys()))
            rec = new_trade(trade_id, known_trades[trade_id], event_dt=event_dt)  # same version -> replace

        elif known_trades and roll < pct_amendments + pct_duplicates + pct_out_of_order:
            trade_id = random.choice(list(known_trades.keys()))
            stale_version = max(1, known_trades[trade_id] - 1)
            rec = new_trade(trade_id, stale_version, event_dt=event_dt)  # lower version -> reject

        elif roll < pct_amendments + pct_duplicates + pct_out_of_order + pct_already_expired:
            trade_id = f"TRD-{uuid.uuid4().hex[:10].upper()}"
            rec = new_trade(trade_id, 1, maturity_offset=(-30, -1), event_dt=event_dt)  # already matured -> expired
            known_trades[trade_id] = 1

        else:
            trade_id = f"TRD-{uuid.uuid4().hex[:10].upper()}"
            rec = new_trade(trade_id, 1, event_dt=event_dt)
            known_trades[trade_id] = 1

        records.append(rec)

    random.shuffle(records)
    return records


def write_batch(records: list[dict], out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    batch_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    out_path = out_dir / f"trades_{batch_ts}.jsonl"
    with out_path.open("w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec) + "\n")
    return out_path


def main():
    parser = argparse.ArgumentParser(description="Generate a mock batch of trade messages.")
    parser.add_argument("--num-trades", type=int, default=500)
    parser.add_argument("--pct-amendments", type=float, default=0.15)
    parser.add_argument("--pct-duplicates", type=float, default=0.05)
    parser.add_argument("--pct-out-of-order", type=float, default=0.05)
    parser.add_argument("--pct-already-expired", type=float, default=0.05)
    parser.add_argument("--out-dir", type=str, default=str(OUTPUT_DIR))
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument(
        "--trade-date", type=str, default=None,
        help="Backdate every record in this batch to this date (YYYY-MM-DD) "
             "instead of 'now' -- used to backfill history.",
    )
    args = parser.parse_args()

    if args.seed is not None:
        random.seed(args.seed)

    event_dt = None
    if args.trade_date:
        day = datetime.strptime(args.trade_date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        event_dt = day + timedelta(hours=random.uniform(0, 23), minutes=random.uniform(0, 59))

    records = generate_batch(
        num_trades=args.num_trades,
        pct_amendments=args.pct_amendments,
        pct_out_of_order=args.pct_out_of_order,
        pct_duplicates=args.pct_duplicates,
        pct_already_expired=args.pct_already_expired,
        event_dt=event_dt,
    )
    out_path = write_batch(records, Path(args.out_dir))
    print(f"Wrote {len(records)} trade messages to {out_path}")


if __name__ == "__main__":
    main()
