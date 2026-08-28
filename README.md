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
dashboard/              Streamlit trade-status dashboard -- runs natively in
                        Snowflake (Streamlit in Snowflake), see below
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
| Gold | `GOLD` | A proper Kimball star: six `dim_*` tables (trader/book/counterparty/product/currency/date), `fct_valid_trades` / `fct_rejected_trades` (facts, FK'd to every dim), `fct_trade_status` (the ACTIVE/EXPIRED + notional_usd view), `rpt_trade_report` (flat, pre-joined reporting view — see "Reporting layer" below), and `valid_trades_snapshot` (Type 2 SCD history). Business-consumable. |

### The GOLD star schema

`fct_valid_trades` and `fct_rejected_trades` carry a surrogate-key foreign
column (`trader_key`, `book_key`, `counterparty_key`, `product_key`,
`currency_key`, `trade_date_key`, `maturity_date_key`) for every `dim_*`
table, generated via `dbt_utils.generate_surrogate_key()` on the dimension
side and `dbt_utils.date_spine()` for `dim_date`. `gold.yml` tests every one
of those FKs with a `relationships` test against its dimension's key — real
referential-integrity checks that weren't possible before this redesign.
The natural-key text columns (`trader`, `book`, `counterparty`,
`product_type`, `currency`) are deliberately kept on the facts too, right
alongside the `_key` columns — a small, fixed-vocabulary denormalization so
a simple query (or the `convert_to_usd()` macro, which needs a real currency
code) doesn't have to join every dimension just to read them.

### Reporting layer

`rpt_trade_report` (`models/gold/rpt_trade_report.sql`) sits on top of the
star schema: `fct_trade_status` joined to `dim_date` twice (trade date and
maturity date), with every filterable attribute already flattened into
plain columns — no joins required by a BI tool or a dashboard. It's what
the dashboard queries, with filters (trader, book, counterparty, product
type, currency, status, maturity date range) applied against it.

### The dashboard — Streamlit in Snowflake, multi-page

Two pages, sharing filter state and query logic via `dashboard/common.py`:

- **Summary** (`dashboard/Summary.py`, the app's entry point — named so
  Streamlit's sidebar nav, which derives a page's label from its filename
  for the entry file, actually reads "Summary" instead of "streamlit app")
  — a
  one-line dynamic narrative computed from the filtered data (trade count,
  total notional, active %, largest exposure), 5 KPI cards, and a 2×2 grid
  of small charts (status, notional by product, notional by currency,
  rejections by reason), each with its own dynamically-computed one-line
  caption (e.g. "USD dominates at 61% of the book") rather than a chart
  left to speak for itself.
- **Trade Details** (`dashboard/pages/1_Trade_Details.py`) — the full
  filtered table, a per-trade drill-down that queries
  `valid_trades_snapshot` (the Type 2 SCD history) for whichever trade is
  selected and reports how many amendments it's had, and the rejected-
  trades audit log with its own reason filter.

It runs natively inside Snowflake (a **Streamlit in Snowflake / SiS** app,
`terraform/streamlit.tf`) rather than as a script on someone's laptop — no
`.env`, no local Python process that has to keep running. It's a Snowflake
object like any other Terraform-managed resource:
`snowflake_stage.dashboard_stage` (`GOLD.DASHBOARD_STAGE`) holds the app
files (`Summary.py`, `common.py`, `pages/1_Trade_Details.py`) plus
`dashboard/environment.yml` (Streamlit in Snowflake reads its package list
from an `environment.yml` alongside the main file — every package in it,
`streamlit`/`pandas`/`plotly`, has to exist in Snowflake's Anaconda
channel; arbitrary `pip` packages aren't installable in the sandboxed SiS
runtime), and `snowflake_streamlit.dashboard` registers the app itself,
running queries on `TRADE_ANALYTICS_WH`. View it in Snowsight under
**Projects → Streamlit**. The file *content* is uploaded via `PUT`,
alongside `terraform/sql/generate_trade_files_procedure.sql`: Terraform
registers the app object and the stage it lives on, and file content is
pushed separately, the same pattern used for the stored procedure's code.

The app code itself works two ways with zero duplication:
`get_active_session()` (in `common.py`) succeeds only when actually running
inside Snowflake; locally (`streamlit run dashboard/Summary.py`,
using `dashboard/requirements.txt` + a populated `.env`) that call raises,
and a `Session.builder` fallback builds an equivalent Snowpark session from
`.env` instead — every query after that point is identical
`session.sql(...).to_pandas()` code either way.

### RBAC & data masking

Two read-only consumer roles sit alongside the two service roles (LOADER,
TRANSFORMER):

| Role | Sees | Masking |
|---|---|---|
| `TRADE_ANALYTICS_TRANSFORMER` | Everything in SILVER/GOLD (dbt's own build role) | None |
| `TRADE_ANALYTICS_COMPLIANCE` | Everything in GOLD, including `fct_rejected_trades` (the audit log) and the raw fact/dimension tables | None -- full fidelity |
| `TRADE_ANALYTICS_ANALYST` | Only `fct_trade_status` and `rpt_trade_report` -- not the underlying tables | `COUNTERPARTY` pseudonymized, `NOTIONAL`/`NOTIONAL_USD` rounded to the nearest \$1M |

Roles themselves are Terraform-managed (`terraform/rbac.tf`), but **who can
select what** is managed by dbt, not Terraform: a `+grants` config in
`dbt_project.yml` (`gold: +grants: select: ['TRADE_ANALYTICS_COMPLIANCE']`)
grants every GOLD object to COMPLIANCE by default, and the two masked
models override that individually
(`grants={'select': ['TRADE_ANALYTICS_COMPLIANCE', 'TRADE_ANALYTICS_ANALYST']}`
in their `config()`) to add ANALYST — deliberately *not* granted at the
folder level, so it can't reach `fct_valid_trades` directly and read
`NOTIONAL`/`COUNTERPARTY` unmasked. dbt re-applies (and would revoke, if a
model's `grants` config changed) these grants on every run — this is a
native dbt feature (`grants` model config), not a workaround.

Masking itself is two Snowflake masking policies
(`macros/create_masking_policies.sql`, created idempotently via an
`on-run-start` hook so they exist before any model tries to attach one),
each a `CASE WHEN CURRENT_ROLE() IN (...)` expression, attached to
`NOTIONAL`/`NOTIONAL_USD`/`COUNTERPARTY` on both `fct_trade_status` and
`rpt_trade_report` via a `post_hook` in each model's `config()`. Rounding
notional to the nearest \$1M (rather than nulling it) lets ANALYST still
see rough exposure size and run aggregate analysis; pseudonymizing
counterparty with a deterministic hash (rather than a single generic
label) lets it still group and count by counterparty without learning
which one it actually is.

Verified live by connecting as each role: `rpt_trade_report` returns
masked values for ANALYST and real ones for COMPLIANCE, and ANALYST is
denied on `fct_valid_trades` directly (`Object 'FCT_VALID_TRADES' does not
exist or not authorized`) — but only once secondary roles are turned off.
Snowflake sessions default to `secondary_roles = ALL`, which combines
every role granted to a user regardless of which one is "current" — this
project's roles are all granted to the same trial-account user (there's
only one person here), so testing ANALYST's restriction from that same
login needs `USE SECONDARY ROLES NONE;` first, or COMPLIANCE's broader
grants silently paper over it. A real deployment would have each role
belong to a different person's login, where this wouldn't come up.

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
  stg_trades -> int_trades_evaluated -> fct_valid_trades / fct_rejected_trades (FK'd to dim_*)
                                              |                        |
                                       fct_trade_status          dim_trader, dim_book,
                                              |                  dim_counterparty, dim_product,
                                       rpt_trade_report           dim_currency, dim_date
                                       (dashboard, filters)
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
   (computed dynamically in the `fct_trade_status` view).
5. Added rule: a trade superseded by a newer version within the same batch
   is logged as rejected rather than silently dropped.
6. Every rejection is written to `fct_rejected_trades`, an append-only
   compliance audit log.

## dbt features on display

- **Incremental models** (`silver`/`gold`) with a self-referencing
  watermark pattern — see `models/silver/int_trades_evaluated.sql`.
- **A custom macro**, `macros/convert_to_usd.sql`: loops over the
  `fx_rates_to_usd` var in `dbt_project.yml` to generate a currency-CASE
  expression, used in `fct_trade_status` to produce `notional_usd`. Change a
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
- **Singular + generic tests**: 68 tests across `not_null`/`unique`/
  `accepted_values`/`relationships` plus one hand-written invariant check
  (`tests/assert_no_trade_in_both_valid_and_rejected.sql`).

## Transient vs. permanent tables, and clustering keys

dbt-snowflake defaults every table/incremental model to `TRANSIENT` (no
Fail-safe storage) unless told otherwise. Most of this project's SILVER and
GOLD objects leave that default as-is, made explicit via `transient=true`
in each model's `config()`: they're a pure function of `BRONZE` (permanent)
plus the current dbt SQL, so if lost, `dbt run` regenerates them exactly —
Fail-safe's extra 7-day recovery window would be cost with no benefit.

`fct_rejected_trades` and `valid_trades_snapshot` are the deliberate
exception: `transient=false`. Both are point-in-time compliance records —
what business logic decided *at the moment* a message arrived or a snapshot
ran. If dbt's rules change later, replaying `BRONZE` would apply the *new*
rules to *old* messages and silently rewrite audit history, so these two
earn the extra Fail-safe protection a real audit record deserves.

`fct_valid_trades`, `fct_rejected_trades` (`cluster_by=['maturity_date']`,
in their dbt `config()`) and `BRONZE.TRADES_RAW` (`cluster_by =
["to_date(loaded_at)"]`, in `terraform/main.tf`) carry explicit clustering
keys — illustrative at this project's row count (Snowflake's automatic
micro-partitioning already handles a table this small), but real once
either table is large enough that a maturity-date-range report or a
by-day ingestion query would otherwise scan most of the table's
partitions. `snowflake_sql/observability_toolkit.sql` §3.8 checks
clustering health via `SYSTEM$CLUSTERING_INFORMATION()`, and §1.9
demonstrates a `TEMPORARY` table for session-scoped ad-hoc debugging that
needs no manual cleanup.

## Orchestration

- **Ingestion** (Snowflake-native): two `snowflake_task` resources in
  `terraform/orchestration.tf`, each with `task_auto_retry_attempts = 2` and
  `suspend_task_after_num_failures = 3`. A `snowflake_alert` checks
  `TASK_HISTORY` every 15 minutes and emails on any failure via a
  `snowflake_email_notification_integration`. `BRONZE.GENERATE_TRADE_FILES`
  itself is deployed via `terraform/sql/generate_trade_files_procedure.sql`
  rather than as a `snowflake_procedure_python` resource, so its Python
  body stays under direct version control, reviewable in one file.
- **Transformation**: dbt run/test is scheduled hourly, and the Type 2 SCD
  snapshot monthly, through dbt Cloud jobs (project reads this repo via a
  deploy key — read-write, so the dbt Cloud IDE can also branch/commit/push
  directly; a read-only key blocks that even though scheduled jobs never
  need write access) — not through Snowflake Tasks;
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
