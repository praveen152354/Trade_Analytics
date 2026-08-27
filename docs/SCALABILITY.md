# Operational questions

## File arrival delays, data quality problems, task failures

- **File arrival delays**: the DAG doesn't wait on a specific file — each
  run generates and loads its own batch, so a "delay" just means the next
  scheduled run's data shows up late; nothing blocks. If this fed from a
  real upstream feed instead of the generator, the `load_to_snowflake` task
  would be replaced by a Snowflake `FileSensor`-equivalent (an Airflow
  sensor polling the stage, or Snowpipe auto-ingest) with a
  `timeout`/`soft_fail` so a missing file alerts instead of hanging the DAG.
- **Data quality problems**: caught at two layers. (1) dbt `data_tests` in
  `models/marts/marts.yml` and `models/staging/stg_trades.yml` (`not_null`,
  `unique`, `accepted_values`) fail the `dbt test` task and email
  `ALERT_EMAIL_TO`. (2) Business-rule rejects (bad version, matured trade)
  never fail the pipeline at all — by design, they're routed to
  `rejected_trades` as data, not errors, since a rejected trade is an
  expected outcome, not a pipeline defect.
- **Task failures**: every Airflow task gets 2 automatic retries
  (`default_args.retries`, `orchestration/airflow/dags/trade_pipeline_dag.py`)
  with a 2-minute backoff before it's marked failed and emails out. `COPY
  INTO ... ON_ERROR = 'SKIP_FILE'` means one malformed file in a batch
  doesn't abort the whole load. dbt's own dependency graph means a failure
  in `stg_trades` blocks `int_trades_evaluated`/`valid_trades`/
  `rejected_trades` from running on bad input rather than silently
  processing partial data (`dbt run` stops downstream models on an upstream
  failure by default).

## Monitoring pipeline health with Snowflake's admin views + Alerts

Query these `SNOWFLAKE.ACCOUNT_USAGE` (account-wide, ~45min-3hr latency) or
`INFORMATION_SCHEMA` (real-time, current session/warehouse only) views:

- **`COPY_HISTORY`** — every `COPY INTO TRADES_RAW`, rows loaded/rows
  parsed/errors, per file. Catches ingestion failures at the file level.
- **`QUERY_HISTORY`** — every query dbt/the loader issued: duration, bytes
  scanned, error code/message, warehouse used. Filter
  `EXECUTION_STATUS = 'FAIL'` to find failed dbt model builds.
- **`WAREHOUSE_METERING_HISTORY`** — credits consumed by
  `TRADE_ANALYTICS_WH` over time; the early-warning signal for runaway
  cost as volume grows.
- **`TASK_HISTORY`** — relevant only if Snowflake Tasks are added later
  (this project uses Airflow instead); shows scheduled task run
  success/failure/skip.

For alerting, two options layered on top of what Airflow already does:

1. **Snowflake `CREATE ALERT`** — a native scheduled alert that runs a
   condition query against `ACCOUNT_USAGE` and fires a notification (email
   via a notification integration) when true, e.g.:
   ```sql
   create alert copy_failures_alert
     warehouse = trade_analytics_wh
     schedule = '30 minute'
     if (exists (
       select 1 from snowflake.account_usage.copy_history
       where status = 'LOAD_FAILED' and last_load_time > dateadd('hour', -1, current_timestamp())
     ))
     then call system$send_email(...);
   ```
   This catches failures even if Airflow itself is down — a level of
   monitoring that lives outside the orchestrator.
2. **Airflow email-on-failure** (already wired, see
   `orchestration/airflow/docker-compose.yml` SMTP config +
   `default_args.email_on_failure` in the DAG) — catches DAG/task-level
   failures with full log context in one click.

## Scaling to 10,000x the trade volume

- **Warehouse**: `TRADE_ANALYTICS_WH` is `XSMALL` with `auto_suspend`. At
  10,000x volume, scale it via `warehouse_size` (Terraform variable) or
  turn on multi-cluster (`min_cluster_count`/`max_cluster_count` in
  `terraform/main.tf`) for concurrency rather than a single bigger
  warehouse, since Airflow/dbt/dashboard load is mostly concurrent readers,
  not one giant query.
- **Ingestion**: swap the internal-stage `PUT`+`COPY INTO` batch load for
  **Snowpipe Streaming** (or Snowpipe auto-ingest off cloud storage) so
  ingestion decouples from the 30-minute Airflow schedule entirely and
  scales to near-continuous arrival without larger/more frequent file PUTs.
- **Stream/merge cost**: the `int_trades_evaluated`→`valid_trades` merge is
  keyed on `trade_id`; at high cardinality, cluster `valid_trades` and
  `int_trades_evaluated` on `trade_id` (or an `date_trunc` of
  `maturity_date` for `trade_status` scans) so the merge's join and the
  `trade_status` view's `maturity_date` filter both prune partitions
  instead of full-scanning.
- **`trade_status`'s computed EXPIRED column**: cheap as a view at current
  volume. At 10,000x, if that view is queried heavily by dashboards, switch
  it to a Snowflake **Dynamic Table** (`target_lag = '5 minutes'`) — same
  "derived, not mutated" semantics, but materialized and incrementally
  refreshed instead of recomputed per query.
- **Orchestration**: a single 30-minute DAG run is fine now; at 10,000x
  trade volume, split ingestion into per-source-system or per-region DAGs
  running in parallel (Airflow `max_active_runs`/task-level parallelism),
  and move from `LocalExecutor` to `CeleryExecutor`/`KubernetesExecutor` so
  task execution scales across workers instead of one machine.
- **dbt**: models are already incremental (not full-refresh), so dbt's own
  cost scales with the size of each new batch, not total historical volume
  — the main lever at 10,000x is warehouse size/concurrency above, not
  rewriting the SQL.
