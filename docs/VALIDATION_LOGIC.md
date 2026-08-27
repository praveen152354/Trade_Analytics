# Validation logic & tech stack rationale

## Business rules, and where each one lives

All rule logic is centralized in one place — `models/intermediate/int_trades_evaluated.sql`
— so there is exactly one definition of "accepted" vs "rejected" instead of the
logic being duplicated/drifting across `valid_trades` and `rejected_trades`.

| # | Rule | Implementation |
|---|------|-----------------|
| 1 | Reject trades with a lower version than existing | `existing_version is not null and version < existing_version` → `decision = 'REJECTED'`, reason `STALE_VERSION_LOWER_THAN_EXISTING`. `existing_version` is the max version ever accepted for that `trade_id`, looked up from the model's own history. |
| 2 | Replace trades with the same version | Same/higher version passes the check above → `ACCEPTED`. `valid_trades` is an incremental **merge** keyed on `trade_id`, so an accepted same-version message overwrites the existing row rather than inserting a duplicate. |
| 3 | Reject trades with a maturity date earlier than today | `maturity_date < current_date()` → `REJECTED`, reason `MATURITY_DATE_IN_PAST`. Evaluated once, at ingestion time. |
| 4 | Mark trades as expired if the maturity date has passed | Deliberately **not** a mutation. `trade_status` is a view over `valid_trades` with `case when maturity_date < current_date() then 'EXPIRED' else 'ACTIVE' end`. A trade's expiry is a pure function of its maturity date and today's date, so recomputing it on read is always correct and requires no scheduled UPDATE job (see docs/SCALABILITY.md for the tradeoff at very high volume). |
| 5 | (Optional) extra rule I added | Same-batch supersession: if two messages for the same `trade_id` arrive in one run, only the highest version is a candidate for acceptance — the rest are logged as rejected (`SUPERSEDED_IN_BATCH`) instead of being silently dropped. Realistic for a trade feed where amendments can arrive faster than the batch cadence. |
| 6 | Log rejected trades for audit | `rejected_trades` is an append-only table, `unique_key = message_id`, never updated or deleted. `int_trades_evaluated` itself is also append-only and additionally records every **accepted** decision, so it doubles as a full decision audit trail (not just rejects) if compliance ever needs "why was this trade accepted at this version". |

## The three-layer dbt DAG

```
stg_trades  ->  int_trades_evaluated  ->  valid_trades
                                      \->  rejected_trades  ->  trade_status (view)
```

- **`stg_trades`** (incremental, append) — flattens the raw JSON `VARIANT`
  into typed columns. Selects from `RAW.TRADES_RAW_STREAM`, a standard
  Snowflake **stream** on the landing table. Reading a stream inside the
  final `INSERT`/`MERGE` statement of a transaction is what *consumes* it in
  Snowflake and advances its offset — this is the "Snowflake feature" used
  to consume newly-arrived trades, rather than re-scanning the whole raw
  table every run.
- **`int_trades_evaluated`** (incremental, append, `unique_key=message_id`) —
  the single decision point described above. It self-references `{{ this }}`
  to look up each trade's current accepted version, which is what lets
  `valid_trades` depend on it without creating a `ref()` cycle.
- **`valid_trades`** (incremental, `merge` on `trade_id`) — current state,
  one row per trade.
- **`rejected_trades`** (incremental, append) — the compliance audit log.
- **`trade_status`** (view) — `valid_trades` plus the computed
  ACTIVE/EXPIRED column; this is what the dashboard and any downstream
  reporting should query.

## Tech stack choices

- **Snowflake internal stage + `COPY INTO`** for ingestion rather than
  Snowpipe: this is a scheduled batch pipeline (Airflow triggers it), so
  Snowpipe's event-driven auto-ingest doesn't add value here and would add
  an extra moving part (cloud notification integration) for a trial account.
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
- **Airflow (Docker Compose)** for orchestration: matches the brief's
  preferred stack, gives DAG-level retries/alerting/history out of the box,
  and is portable to Cloud Composer with no DAG changes.
- **Terraform (`snowflakedb/snowflake` provider)** for IaC: the warehouse,
  database/schemas, roles, stage, file format, raw table and stream are all
  declared once and reproducible; nothing in this project was clicked into
  existence in the Snowflake UI.
