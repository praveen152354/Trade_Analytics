-- Deployed via a versioned SQL script rather than a Terraform resource:
-- this keeps the stored procedure's Python source under direct version
-- control, with its full body reviewable in one file rather than embedded
-- in HCL. Run once via data_generator's Snowflake connection (or the
-- Snowsight worksheet) before `terraform apply` creates
-- GENERATE_TRADE_FILES_TASK, which calls it.
--
-- python -c "from load_to_snowflake import get_connection; get_connection().cursor().execute(open('terraform/sql/generate_trade_files_procedure.sql').read())"
-- (or paste directly into a Snowsight worksheet as ACCOUNTADMIN)

CREATE OR REPLACE PROCEDURE TRADE_ANALYTICS.BRONZE.GENERATE_TRADE_FILES(NUM_TRADES NUMBER)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'generate_trade_file'
COMMENT = 'Generates a batch of mock trade messages and writes it as .jsonl straight onto BRONZE.TRADES_STAGE.'
AS
$$
import io
import json
import random
import string
import uuid
from datetime import datetime, timedelta, timezone

CURRENCIES = ["USD", "EUR", "GBP", "JPY", "CHF", "AUD"]
PRODUCT_TYPES = ["FX_SPOT", "FX_FORWARD", "IRS", "FX_OPTION", "BOND"]
COUNTERPARTIES = [
    "GOLDMAN_SACHS", "JP_MORGAN", "BARCLAYS", "DEUTSCHE_BANK",
    "CITI", "HSBC", "MORGAN_STANLEY", "UBS",
]
TRADERS = ["trader_" + c for c in string.ascii_lowercase[:8]]
BOOKS = ["RATES_BOOK_1", "RATES_BOOK_2", "FX_BOOK_1", "CREDIT_BOOK_1"]


def _random_maturity(days_min, days_max):
    d = datetime.now(timezone.utc).date() + timedelta(days=random.randint(days_min, days_max))
    return d.isoformat()


def _new_trade(trade_id, version, maturity_offset=(1, 730)):
    now = datetime.now(timezone.utc)
    return {
        "trade_id": trade_id,
        "version": version,
        "source_system": "SNOWPARK_MOCK_FEED",
        "message_id": str(uuid.uuid4()),
        "event_timestamp": now.isoformat(),
        "trade_date": now.date().isoformat(),
        "maturity_date": _random_maturity(*maturity_offset),
        "product_type": random.choice(PRODUCT_TYPES),
        "counterparty": random.choice(COUNTERPARTIES),
        "trader": random.choice(TRADERS),
        "book": random.choice(BOOKS),
        "currency": random.choice(CURRENCIES),
        "notional": round(random.uniform(100_000, 50_000_000), 2),
        "price": round(random.uniform(0.5, 150.0), 4),
        "status": "NEW",
    }


def _generate_batch(num_trades):
    records = []
    known_trades = {}

    for _ in range(num_trades):
        roll = random.random()

        if known_trades and roll < 0.15:
            trade_id = random.choice(list(known_trades.keys()))
            new_version = known_trades[trade_id] + 1
            known_trades[trade_id] = new_version
            rec = _new_trade(trade_id, new_version)
        elif known_trades and roll < 0.20:
            trade_id = random.choice(list(known_trades.keys()))
            rec = _new_trade(trade_id, known_trades[trade_id])
        elif known_trades and roll < 0.25:
            trade_id = random.choice(list(known_trades.keys()))
            stale_version = max(1, known_trades[trade_id] - 1)
            rec = _new_trade(trade_id, stale_version)
        elif roll < 0.30:
            trade_id = f"TRD-{uuid.uuid4().hex[:10].upper()}"
            rec = _new_trade(trade_id, 1, maturity_offset=(-30, -1))
            known_trades[trade_id] = 1
        else:
            trade_id = f"TRD-{uuid.uuid4().hex[:10].upper()}"
            rec = _new_trade(trade_id, 1)
            known_trades[trade_id] = 1

        records.append(rec)

    random.shuffle(records)
    return records


def generate_trade_file(session, num_trades: int) -> str:
    records = _generate_batch(int(num_trades))

    buf = io.BytesIO()
    for rec in records:
        buf.write((json.dumps(rec) + "\n").encode("utf-8"))
    buf.seek(0)

    batch_ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    file_name = f"trades_{batch_ts}.jsonl"
    session.file.put_stream(buf, f"@BRONZE.TRADES_STAGE/{file_name}", auto_compress=True, overwrite=True)

    return f"Wrote {len(records)} trades to {file_name}"
$$;
