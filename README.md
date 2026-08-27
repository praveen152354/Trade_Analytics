# Trade Analytics — Data Engineering Case Study

An end-to-end trade ETL pipeline: mock trades are generated straight onto a
Snowflake stage, ingested on a schedule, validated against version/maturity
business rules in dbt, and split into valid/rejected tables for compliance —
orchestrated natively in Snowflake, with dbt run/test scheduled through dbt
Cloud.

```
data_generator/        local generator + loader (manual/dev use — see below)
terraform/              IaC for all Snowflake objects: warehouse, db, schemas,
                        roles, stage, file format, raw table, stream, the
                        generation/ingestion Tasks, and the failure alert
terraform/sql/          the one object Terraform can't manage yet (see below)
dbt/trade_analytics/    staging -> business-rule evaluation -> valid/rejected marts
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

## Pipeline at a glance

```
Snowflake Task (every N min, configurable)
  -> CALL RAW.GENERATE_TRADE_FILES(...)     -- Snowpark proc, writes .jsonl to the stage
       |
Snowflake Task (every 5 min, configurable)
  -> COPY INTO RAW.TRADES_RAW FROM @RAW.TRADES_STAGE
       |
RAW.TRADES_RAW --(stream)--> dbt (scheduled hourly via dbt Cloud):
  stg_trades -> int_trades_evaluated -> valid_trades / rejected_trades -> trade_status
```

Trade generation and ingestion are two independently-scheduled Snowflake
Tasks rather than one script: a Snowpark Python procedure
(`RAW.GENERATE_TRADE_FILES`) generates a batch and writes it as a file
straight onto the `RAW.TRADES_STAGE` internal stage — genuine cloud object
storage, Snowflake-managed, no external cloud account needed — and a
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

## Orchestration

- **Ingestion** (Snowflake-native): two `snowflake_task` resources in
  `terraform/orchestration.tf`, each with `task_auto_retry_attempts = 2` and
  `suspend_task_after_num_failures = 3`. A `snowflake_alert` checks
  `TASK_HISTORY` every 15 minutes and emails on any failure via a
  `snowflake_email_notification_integration`. `RAW.GENERATE_TRADE_FILES`
  itself is deployed via `terraform/sql/generate_trade_files_procedure.sql`
  rather than as a `snowflake_procedure_python` resource — the installed
  provider version has a read-back bug for that resource type; see the
  comment at the top of that SQL file.
- **Transformation**: dbt run/test is scheduled hourly through a dbt Cloud
  job (project reads this repo directly via a read-only deploy key), not
  through Snowflake Tasks — `EXECUTE DBT PROJECT` (dbt Projects on
  Snowflake) is a newer, still-evolving feature, and dbt Cloud's own
  scheduler gives retries/logs/alerting for free without adding a
  dependency on it.
- **Alternative**: `orchestration/airflow/` is a complete, working Docker
  Compose Airflow stack that runs generate → load → `dbt run` → `dbt test`
  as one DAG. It's kept as a documented alternative (the case study's
  preferred stack lists Airflow explicitly) but isn't the path this repo
  runs day to day.

See [docs/SCALABILITY.md](docs/SCALABILITY.md) for the Snowflake
`ACCOUNT_USAGE`/`TASK_HISTORY` queries used for pipeline health monitoring
and how failures, delays, and data quality issues are handled.
