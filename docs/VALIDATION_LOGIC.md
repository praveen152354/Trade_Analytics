# Validation logic & tech stack rationale

## Business rules, and where each one lives

All rule logic is centralized in one place — `models/intermediate/int_trades_evaluated.sql`
— so there is exactly one definition of "accepted" vs "rejected" instead of the
logic being duplicated/drifting across `fct_valid_trades` and `fct_rejected_trades`.

| # | Rule | Implementation |
|---|------|-----------------|
| 1 | Reject trades with a lower version than existing | `existing_version is not null and version < existing_version` → `decision = 'REJECTED'`, reason `STALE_VERSION_LOWER_THAN_EXISTING`. `existing_version` is the max version ever accepted for that `trade_id`, looked up from the model's own history. |
| 2 | Replace trades with the same version | Same/higher version passes the check above → `ACCEPTED`. `fct_valid_trades` is an incremental **merge** keyed on `trade_id`, so an accepted same-version message overwrites the existing row rather than inserting a duplicate. |
| 3 | Reject trades with a maturity date earlier than today | `maturity_date < current_date()` → `REJECTED`, reason `MATURITY_DATE_IN_PAST`. Evaluated once, at ingestion time. |
| 4 | Mark trades as expired if the maturity date has passed | Deliberately **not** a mutation. `fct_trade_status` is a view over `fct_valid_trades` with `case when maturity_date < current_date() then 'EXPIRED' else 'ACTIVE' end`. A trade's expiry is a pure function of its maturity date and today's date, so recomputing it on read is always correct and requires no scheduled UPDATE job (see docs/SCALABILITY.md for the tradeoff at very high volume). |
| 5 | (Optional) extra rule I added | Same-batch supersession: if two messages for the same `trade_id` arrive in one run, only the highest version is a candidate for acceptance — the rest are logged as rejected (`SUPERSEDED_IN_BATCH`) instead of being silently dropped. Realistic for a trade feed where amendments can arrive faster than the batch cadence. |
| 6 | Log rejected trades for audit | `fct_rejected_trades` is an append-only table, `unique_key = message_id`, never updated or deleted. `int_trades_evaluated` itself is also append-only and additionally records every **accepted** decision, so it doubles as a full decision audit trail (not just rejects) if compliance ever needs "why was this trade accepted at this version". |

## The GOLD star schema and dbt DAG

```
stg_trades -> int_trades_evaluated -> fct_valid_trades ---> fct_trade_status -> rpt_trade_report
                                   \-> fct_rejected_trades        ^
                                                                   |
                              dim_trader, dim_book, dim_counterparty,
                                dim_product, dim_currency, dim_date
```

- **`stg_trades`** (incremental, append) — flattens the raw JSON `VARIANT`
  into typed columns. Selects from `BRONZE.TRADES_RAW_STREAM`, a standard
  Snowflake **stream** on the landing table. Reading a stream inside the
  final `INSERT`/`MERGE` statement of a transaction is what *consumes* it in
  Snowflake and advances its offset — this is the "Snowflake feature" used
  to consume newly-arrived trades, rather than re-scanning the whole raw
  table every run.
- **`int_trades_evaluated`** (incremental, append, `unique_key=message_id`) —
  the single decision point described above. It self-references `{{ this }}`
  to look up each trade's current accepted version, which is what lets
  `fct_valid_trades` depend on it without creating a `ref()` cycle.
- **`dim_trader` / `dim_book` / `dim_counterparty` / `dim_product` /
  `dim_currency`** (table, full-refresh) — one row per distinct value ever
  seen in `int_trades_evaluated` (accepted *or* rejected, so a
  counterparty that only ever appears on a rejected message still gets a
  row), with a surrogate key via `dbt_utils.generate_surrogate_key()`.
  Small, fixed-vocabulary reference data — cheap to rebuild in full every
  run, no incremental logic needed.
- **`dim_date`** (table, full-refresh) — a standard Kimball date dimension
  built with `dbt_utils.date_spine()`, bounded by the
  `date_dim_start_date`/`date_dim_end_date` vars in `dbt_project.yml`.
- **`fct_valid_trades`** (incremental, `merge` on `trade_id`) — current
  state, one row per trade, joined out to every `dim_*` table for
  surrogate-key FKs (`trader_key`, `book_key`, `counterparty_key`,
  `product_key`, `currency_key`, `trade_date_key`, `maturity_date_key`).
  The natural-key text columns are kept alongside the FKs — see the
  "GOLD star schema" section of the top-level README for why.
- **`fct_rejected_trades`** (incremental, append) — the compliance audit
  log, with the same dimensional FKs as `fct_valid_trades`.
- **`fct_trade_status`** (view) — `fct_valid_trades` plus the computed
  ACTIVE/EXPIRED column and `notional_usd` (via `convert_to_usd()`).
- **`rpt_trade_report`** (view) — the flat reporting layer: `fct_trade_status`
  joined to `dim_date` twice (trade date and maturity date), with every
  filterable attribute already denormalized into plain columns. This is
  what `dashboard/Summary.py` and any downstream BI tool should
  query — no joins required.
- **`valid_trades_snapshot`** (dbt snapshot, `check` strategy, Type 2 SCD) —
  a point-in-time history of `fct_valid_trades`. Unlike the models above it
  isn't part of the hourly `dbt run`; it's invoked separately (`dbt
  snapshot`) on a month-end schedule, since its purpose is capturing
  end-of-month positions for compliance/reporting, not tracking every
  intra-day change. See `snapshots/valid_trades_snapshot.sql`.

## The currency-conversion macro

`macros/convert_to_usd.sql` takes an amount column and a currency column and
returns a `CASE` expression converting to USD, built by looping over the
`fx_rates_to_usd` var in `dbt_project.yml`:

```sql
{{ convert_to_usd('notional', 'currency') }} as notional_usd
```

The macro is the payoff of moving repeated logic out of hand-written SQL:
the FX table lives in exactly one place (`dbt_project.yml`), every call site
stays in sync automatically, and adding a seventh currency is a one-line
var change rather than finding and editing every `CASE` statement that
happens to convert currency.

**FX rates, deduplicated**: `BRONZE.FX_RATES_RAW` (S3 → external stage →
`INGEST_FX_RATES_TASK`, once daily — see `terraform/s3_integration.tf`)
lands real daily FX rates and is deliberately append-only — if a file is
edited and manually re-uploaded under the same name, Snowflake's `COPY
INTO` treats it as new and loads it again rather than overwriting, so the
same `(as_of_date, currency)` can legitimately appear more than once in
BRONZE. `silver.fx_rates` resolves that: a merge-on-latest incremental
model (`unique_key=['as_of_date', 'currency']`), the exact same pattern as
`fct_valid_trades`, just keyed differently. Querying `silver.fx_rates` always
returns one current row per date+currency; `BRONZE.FX_RATES_RAW` keeps
every version ever loaded, for audit.

**Still a future integration point**: `convert_to_usd()` still reads the
static `fx_rates_to_usd` var in `dbt_project.yml`, not `silver.fx_rates`.
Swapping the macro to join against live rates instead of a hardcoded table
is a natural next step, not done yet since it wasn't part of the original
ask.

## Tech stack choices

- **Snowflake internal stage + `COPY INTO`** for ingestion rather than
  Snowpipe: this is a scheduled batch pipeline (a Snowflake Task triggers
  it — see the "Orchestration" section of the README), so Snowpipe's
  event-driven auto-ingest doesn't add value here and would add an extra
  moving part (cloud notification integration) for a trial account.
  Swapping to Snowpipe/Snowpipe Streaming later is a drop-in change — the
  stage/file-format/raw table shape stays identical.
- **Streams + incremental dbt models** as the "processing engine" (per the
  brief) instead of Snowflake Tasks running raw SQL: keeps all business
  logic in version-controlled, testable dbt SQL instead of split between
  Task DDL and application code.
- **dbt merge-incremental models** rather than a Python/pandas transform:
  the rules are all set-based (version comparison, date comparison), which
  Snowflake's query engine does far more efficiently at scale than
  row-by-row Python, and dbt gives us tests, docs, and lineage for free.
- **Snowflake Tasks for ingestion, dbt Cloud for transformation** as the
  primary path: each tool orchestrates the part it's actually built for,
  with retries/alerting/history out of the box, no extra system to run.
  **Airflow (Docker Compose)** is kept as a genuine, working alternative
  (`orchestration/airflow/`) — matches the brief's preferred stack, gives
  DAG-level retries/alerting/history out of the box, and is a common
  reference pattern for running this whole project end-to-end from a
  single local machine against the same cloud Snowflake account.
- **Terraform (`snowflakedb/snowflake` provider)** for IaC: the warehouse,
  database/schemas, roles, stage, file format, raw table and stream are all
  declared once and reproducible; nothing in this project was clicked into
  existence in the Snowflake UI.
