# Trade Analytics — Data Engineering Case Study

An end-to-end trade ETL pipeline built on a **medallion architecture**
(BRONZE → SILVER → GOLD): mock trades are generated straight onto a
Snowflake stage, ingested on a schedule, validated against version/maturity
business rules in dbt, and split into valid/rejected tables for compliance —
orchestrated natively in Snowflake, with dbt run/test/snapshot scheduled
through dbt Cloud.

```
data_generator/        local generator + loader (manual/dev use — see below)
terraform/              IaC for all Snowflake objects: warehouse, db, schemas,
                        roles, stage, file format, raw table, stream, the
                        generation/ingestion Tasks, and the failure alert
terraform/sql/          the one object Terraform can't manage yet (see below)
snowflake_sql/          ready-to-run SQL: debugging, time travel, cost/perf
                        optimization, observability, governance
dbt/trade_analytics/    models/silver -> models/gold -> snapshots (Type 2 SCD)
orchestration/airflow/  Docker Compose Airflow stack — an alternative
                        orchestrator, documented but not the primary path
dashboard/              optional Streamlit trade-status dashboard
.github/workflows/      CI/CD for dbt and Terraform
docs/                   architecture diagram, setup guide, validation logic,
                        scalability/monitoring write-up
```

See **[docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)** for step-by-step setup,
**[docs/VALIDATION_LOGIC.md](docs/VALIDATION_LOGIC.md)** for how each
business rule is implemented and why the stack is shaped this way, and
**[docs/SCALABILITY.md](docs/SCALABILITY.md)** for how the pipeline handles
failures, is monitored via Snowflake's admin views, and scales to 10,000x
volume. The architecture diagram source is
[docs/architecture.puml](docs/architecture.puml).

## Medallion architecture

| Layer | Schema | Contents |
|---|---|---|
| Bronze | `BRONZE` | Raw landing: `TRADES_RAW`/`FX_RATES_RAW` tables, `TRADES_STAGE` internal stage + `FX_RATES_STAGE` external (S3) stage, `TRADES_RAW_STREAM` CDC stream, the `GENERATE_TRADE_FILES` procedure, three orchestration Tasks — plus `base_trades_raw`/`base_fx_rates_raw`, thin dbt passthrough views that give BRONZE a real, browsable node in the lineage graph. |
| Silver | `SILVER` | `stg_trades` + `int_trades_evaluated` (business-rule decisions for trades), and `fx_rates` (merge-dedup of `FX_RATES_RAW` down to one row per date+currency) — cleansed, conformed, not yet business-facing. |
| Gold | `GOLD` | `valid_trades`, `rejected_trades`, `trade_status` (marts), and `valid_trades_snapshot` (Type 2 SCD history). Business-consumable. |

dbt's own folder convention (`models/bronze/`, `models/silver/`,
`models/gold/`) matches the physical schemas 1:1 in this project, though
that's a project choice, not a dbt requirement — see the comment at the top
of `dbt_project.yml`. `models/bronze/` holds only `sources.yml`: dbt
doesn't materialize anything into BRONZE itself (Terraform and the Snowpark
procedure own that), but declaring it as a dbt source still gives the
landing layer a real node in dbt's lineage graph instead of leaving it
invisible to `dbt docs`/`dbt ls`.

## Pipeline at a glance

```
Snowflake Task (every N min, configurable)
  -> CALL BRONZE.GENERATE_TRADE_FILES(...)     -- Snowpark proc, writes .jsonl to the stage
       |
Snowflake Task (every 5 min, configurable)
  -> COPY INTO BRONZE.TRADES_RAW FROM @BRONZE.TRADES_STAGE
       |
BRONZE.TRADES_RAW --(stream)--> dbt (scheduled hourly via dbt Cloud):
  stg_trades -> int_trades_evaluated -> valid_trades / rejected_trades -> trade_status
                                              |
                              dbt Cloud (monthly, 1st @ 01:00 UTC):
                              valid_trades_snapshot (Type 2 SCD, dbt snapshot)
```

Trade generation and ingestion are two independently-scheduled Snowflake
Tasks rather than one script: a Snowpark Python procedure
(`BRONZE.GENERATE_TRADE_FILES`) generates a batch and writes it as a file
straight onto the `BRONZE.TRADES_STAGE` internal stage — genuine cloud
object storage, Snowflake-managed, no external cloud account needed — and a
separate task polls that stage on its own cadence and `COPY INTO`s whatever
it finds. This decouples "how often trades arrive" from "how often we
ingest," which is closer to how a real upstream feed would behave.

Business rules (all applied in `int_trades_evaluated`, see
[docs/VALIDATION_LOGIC.md](docs/VALIDATION_LOGIC.md) for detail):
1. Reject a trade with a version lower than the one already on file.
2. A same-version message replaces the existing row (merge on `trade_id`).
3. Reject a trade whose maturity date is already in the past.
4. A valid trade is marked `EXPIRED` once its maturity date passes
   (computed dynamically in the `trade_status` view).
5. Added rule: a trade superseded by a newer version within the same batch
   is logged as rejected rather than silently dropped.
6. Every rejection is written to `rejected_trades`, an append-only
   compliance audit log.

## dbt features on display

- **Incremental models** (`silver`/`gold`) with a self-referencing
  watermark pattern — see `models/silver/int_trades_evaluated.sql`.
- **A custom macro**, `macros/convert_to_usd.sql`: loops over the
  `fx_rates_to_usd` var in `dbt_project.yml` to generate a currency-CASE
  expression, used in `trade_status` to produce `notional_usd`. Change a
  rate (or add a currency) in one place in `dbt_project.yml` and every call
  site picks it up — no SQL edits.
- **A Type 2 SCD snapshot**, `snapshots/valid_trades_snapshot.sql` —
  dbt's native `check`-strategy snapshot, tracking every change to a
  trade's version/maturity/notional/price/currency/counterparty/trader/
  book/product_type over time via `dbt_valid_from`/`dbt_valid_to`. Run on
  a month-end schedule (dbt Cloud job, cron `0 1 1 * *` — 01:00 UTC on the
  1st of each month) to capture point-in-time, end-of-month trade-book
  positions for compliance/reporting.
- **Custom schema macro** (`macros/get_custom_schema_name.sql`) so model
  schema config maps directly onto the medallion schemas instead of dbt's
  default `<target_schema>_<custom>` concatenation.
- **Singular + generic tests**: 19 tests across `not_null`/`unique`/
  `accepted_values` plus one hand-written invariant check
  (`tests/assert_no_trade_in_both_valid_and_rejected.sql`).

## Orchestration

- **Ingestion** (Snowflake-native): two `snowflake_task` resources in
  `terraform/orchestration.tf`, each with `task_auto_retry_attempts = 2` and
  `suspend_task_after_num_failures = 3`. A `snowflake_alert` checks
  `TASK_HISTORY` every 15 minutes and emails on any failure via a
  `snowflake_email_notification_integration`. `BRONZE.GENERATE_TRADE_FILES`
  itself is deployed via `terraform/sql/generate_trade_files_procedure.sql`
  rather than as a `snowflake_procedure_python` resource — the installed
  provider version has a read-back bug for that resource type; see the
  comment at the top of that SQL file.
- **Transformation**: dbt run/test is scheduled hourly, and the Type 2 SCD
  snapshot monthly, through dbt Cloud jobs (project reads this repo
  directly via a read-only deploy key) — not through Snowflake Tasks;
  `EXECUTE DBT PROJECT` (dbt Projects on Snowflake) is a newer,
  still-evolving feature, and dbt Cloud's own scheduler gives
  retries/logs/alerting for free without adding a dependency on it.
- **Alternative**: `orchestration/airflow/` is a complete, working Docker
  Compose Airflow stack that runs generate → load → `dbt run` → `dbt test`
  as one DAG. It's kept as a documented alternative (the case study's
  preferred stack lists Airflow explicitly) but isn't the path this repo
  runs day to day.

See [docs/SCALABILITY.md](docs/SCALABILITY.md) for the Snowflake
`ACCOUNT_USAGE`/`TASK_HISTORY` queries used for pipeline health monitoring
and how failures, delays, and data quality issues are handled, and
[snowflake_sql/observability_toolkit.sql](snowflake_sql/observability_toolkit.sql)
for a ready-to-run library of debugging, time-travel, optimization, and
monitoring queries against this project's actual objects.
