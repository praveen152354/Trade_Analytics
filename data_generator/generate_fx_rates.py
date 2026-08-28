"""
Generates one daily FX-rates CSV per day for a date range, matching the
format INGEST_FX_RATES_TASK expects (see terraform/s3_integration.tf):
one row per currency, columns as_of_date,currency,rate_to_usd.

Rates aren't static across days -- each day's rate is the previous day's
rate nudged by a small random walk (+/- ~0.6% daily), so a month of files
looks like a real (if fake) daily feed rather than 30 identical copies.
USD is always exactly 1.0 (it's the base currency being converted to).

These files are meant to be manually uploaded to S3 (one at a time, or in
bulk) to exercise the INGEST_FX_RATES_TASK pipeline -- see
docs/SETUP_GUIDE.md and terraform/s3_integration.tf. This script does not
upload anything itself.
"""

import argparse
import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

# Starting rates, matching the ones used when the integration was first tested.
BASE_RATES_TO_USD = {
    "USD": 1.0,
    "EUR": 1.081,
    "GBP": 1.273,
    "JPY": 0.00668,
    "CHF": 1.119,
    "AUD": 0.652,
}

DAILY_VOLATILITY = 0.006  # ~0.6% max move per day, per currency

OUTPUT_DIR = Path(__file__).parent / "output" / "fx_rates"


def walk_rates(previous: dict[str, float]) -> dict[str, float]:
    """One day's rates, derived from the previous day's via a small random walk."""
    next_rates = {}
    for currency, rate in previous.items():
        if currency == "USD":
            next_rates[currency] = 1.0
            continue
        pct_move = random.uniform(-DAILY_VOLATILITY, DAILY_VOLATILITY)
        next_rates[currency] = round(rate * (1 + pct_move), 6)
    return next_rates


def write_day_file(as_of: date, rates: dict[str, float], out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{as_of.isoformat()}.csv"
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["as_of_date", "currency", "rate_to_usd"])
        for currency, rate in rates.items():
            writer.writerow([as_of.isoformat(), currency, rate])
    return out_path


def generate_range(start: date, num_days: int, out_dir: Path, seed: int | None = None) -> list[Path]:
    if seed is not None:
        random.seed(seed)

    written = []
    rates = dict(BASE_RATES_TO_USD)
    for i in range(num_days):
        as_of = start + timedelta(days=i)
        rates = walk_rates(rates)
        written.append(write_day_file(as_of, rates, out_dir))
    return written


def main():
    parser = argparse.ArgumentParser(description="Generate one daily FX-rates CSV per day for a date range.")
    parser.add_argument(
        "--start-date",
        type=str,
        default=(date.today() + timedelta(days=1)).isoformat(),
        help="First date to generate, YYYY-MM-DD. Default: tomorrow.",
    )
    parser.add_argument("--num-days", type=int, default=30)
    parser.add_argument("--out-dir", type=str, default=str(OUTPUT_DIR))
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    start = datetime.strptime(args.start_date, "%Y-%m-%d").date()
    files = generate_range(start, args.num_days, Path(args.out_dir), args.seed)

    print(f"Wrote {len(files)} files to {args.out_dir}:")
    for f in files:
        print(f"  {f.name}")


if __name__ == "__main__":
    main()
