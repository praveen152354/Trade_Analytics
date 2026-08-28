"""
Backfills historical trade data: one self-contained batch per day for the
last N days, each stamped with that day's date via generate_trades.py's
--trade-date override, so GOLD (and the dashboard's by-month/by-quarter
breakdowns) show a real spread of trade_date values instead of everything
landing on the day the generator happened to run.

Each day's batch is independent (its own trade_ids, its own mix of new/
amended/duplicate/stale/already-expired messages) -- matches how the
production GENERATE_TRADE_FILES_TASK batches work, just backdated.

Usage:
    python data_generator/generate_backfill.py --days 30 --trades-per-day 100
    python data_generator/load_to_snowflake.py --file-glob "data_generator/output/*.jsonl"
    (then a normal `dbt run` to process everything through int_trades_evaluated -> GOLD)
"""

import argparse
from datetime import datetime, timedelta, timezone
from pathlib import Path

from generate_trades import generate_batch, write_batch

OUTPUT_DIR = Path(__file__).parent / "output"


def main():
    parser = argparse.ArgumentParser(description="Backfill N days of historical trade batches.")
    parser.add_argument("--days", type=int, default=30, help="How many days back to backfill (not counting today).")
    parser.add_argument("--trades-per-day", type=int, default=100)
    parser.add_argument("--pct-amendments", type=float, default=0.15)
    parser.add_argument("--pct-duplicates", type=float, default=0.05)
    parser.add_argument("--pct-out-of-order", type=float, default=0.05)
    parser.add_argument("--pct-already-expired", type=float, default=0.05)
    parser.add_argument("--out-dir", type=str, default=str(OUTPUT_DIR))
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    today = datetime.now(timezone.utc).date()
    total_records = 0

    for days_ago in range(args.days, 0, -1):
        day = today - timedelta(days=days_ago)
        event_dt = datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc) + timedelta(
            hours=12
        )
        records = generate_batch(
            num_trades=args.trades_per_day,
            pct_amendments=args.pct_amendments,
            pct_out_of_order=args.pct_out_of_order,
            pct_duplicates=args.pct_duplicates,
            pct_already_expired=args.pct_already_expired,
            event_dt=event_dt,
        )
        out_path = write_batch(records, out_dir)
        total_records += len(records)
        print(f"{day.isoformat()}: wrote {len(records)} messages -> {out_path.name}")

    print(f"Backfill complete: {total_records} messages across {args.days} days in {out_dir}")


if __name__ == "__main__":
    main()
