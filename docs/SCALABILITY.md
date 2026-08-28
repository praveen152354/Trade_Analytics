# Operational questions

## File arrival delays, data quality problems, task failures

- **File arrival delays**: generation and ingestion are two *independently
  scheduled* Snowflake Tasks (`GENERATE_TRADE_FILES_TASK` every 2 min,
  `INGEST_TRADES_TASK` every 5 min, both configurable in
  `terraform/variables.tf`) rather than one script waiting on the other.
  `INGEST_TRADES_TASK` just polls the stage and `COPY INTO`s whatever is
  there; if a file arrives late, it's picked up on the next poll instead of
  causing a failure or a stall. Nothing in the design assumes a file will
  exist by a specific time.
- **Data quality problems**: caught at two layers. (1) dbt `data_tests` in
  `models/gold/gold.yml` and `models/silver/stg_trades.yml` (68 tests:
  `not_null`, `unique`, `accepted_values`, and — since the GOLD star-schema
  redesign — `relationships` tests verifying every fact FK resolves to its
  dimension) fail the dbt Cloud job and trigger its configured
  notifications. (2) Business-rule rejects (bad version, matured trade)
  never fail the pipeline at all — by design, they're routed to
  `fct_rejected_trades` as data, not errors, since a rejected trade is an
  expected outcome, not a pipeline defect.
- **Task failures**: both Snowflake Tasks have `task_auto_retry_attempts = 2`
  (automatic retry of a failed run) and `suspend_task_after_num_failures = 3`
  (auto-suspend after 3 consecutive failures, so a broken task can't spin
  forever burning warehouse credits) — see `terraform/orchestration.tf`.
  `COPY INTO ... ON_ERROR = 'SKIP_FILE'` means one malformed file in a
  batch doesn't abort the whole load. dbt's own dependency graph means a
  failure in `stg_trades` blocks `int_trades_evaluated`/`fct_valid_trades`/
  `fct_rejected_trades` from running on bad input rather than silently
  processing partial data (`dbt run` stops downstream models on an upstream
  failure by default). A `snowflake_alert` (`TASK_FAILURE_ALERT`) checks
  `TASK_HISTORY` every 15 minutes and emails `alert_email` if either task
  failed — this fires even if dbt Cloud or anything outside Snowflake is
  down, since it's entirely native.

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
- **`TASK_HISTORY`** — real-time (`INFORMATION_SCHEMA.TASK_HISTORY`, no
  latency) or historical (`ACCOUNT_USAGE.TASK_HISTORY`); shows every
  `GENERATE_TRADE_FILES_TASK` / `INGEST_TRADES_TASK` run's
  success/failure/skip. This is the primary health signal for this
  project's orchestration.

Alerting is implemented, not just described — `terraform/orchestration.tf`
creates:

1. **`snowflake_alert.task_failure_alert`** — a native scheduled alert
   (`alert_schedule { interval = 15 }`) whose condition queries
   `INFORMATION_SCHEMA.TASK_HISTORY` for either task in a `'FAILED'` state
   in the last 15 minutes, and whose action calls `SYSTEM$SEND_EMAIL` via
   the `TRADE_PIPELINE_ALERT` email notification integration. This fires
   independent of dbt Cloud or anything outside Snowflake — it works even
   if the whole rest of the pipeline is down.
   (Note: a Snowflake Task's own `ERROR_INTEGRATION` property only accepts
   cloud-messaging integrations — SNS/Pub-Sub/Event Grid — not `EMAIL`, so
   email alerting has to go through an `ALERT` like this rather than being
   set directly on the task.)
2. **dbt Cloud job notifications** (Deploy → Notifications on the job) —
   catches `dbt run`/`dbt test` failures with full log context, independent
   of the Snowflake-side alert above.

## Scaling to 10,000x the trade volume

- **Warehouse**: `TRADE_ANALYTICS_WH` is `XSMALL` with `auto_suspend`. At
  10,000x volume, scale it via `warehouse_size` (Terraform variable) or
  turn on multi-cluster (`min_cluster_count`/`max_cluster_count` in
  `terraform/main.tf`) for concurrency rather than a single bigger
  warehouse, since Tasks/dbt/dashboard load is mostly concurrent readers,
  not one giant query.
- **Ingestion**: swap the Task-driven `COPY INTO` poll for **Snowpipe
  Streaming** (or Snowpipe auto-ingest, if trades start landing in genuine
  external cloud storage instead of the Snowflake-managed stage) so
  ingestion decouples from the 5-minute Task poll entirely and scales to
  near-continuous arrival without larger/more frequent batch files.
- **Stream/merge cost**: the `int_trades_evaluated`→`fct_valid_trades` merge
  is keyed on `trade_id`. `fct_valid_trades` and `fct_rejected_trades`
  already carry `cluster_by=['maturity_date']` (set in their dbt `config()`
  — see `rpt_trade_report`'s and the dashboard's maturity-date-range filter,
  the query pattern this key is aimed at); at high cardinality, add a
  second key on `trade_id` for `int_trades_evaluated` too, so the merge's
  join also prunes partitions instead of full-scanning. At this project's
  row count both are illustrative — Snowflake's automatic
  micro-partitioning already handles a table this small.
- **`fct_trade_status`'s computed EXPIRED column**: cheap as a view at
  current volume. At 10,000x, if that view is queried heavily by
  dashboards, switch it to a Snowflake **Dynamic Table**
  (`target_lag = '5 minutes'`) — same "derived, not mutated" semantics, but
  materialized and incrementally refreshed instead of recomputed per query.
- **Orchestration**: today's two Snowflake Tasks are fine at current
  volume; at 10,000x, split ingestion into multiple Tasks per
  source-system/region (Snowflake Tasks scale horizontally the same way —
  each is independent) rather than one Task doing everything, and consider
  moving dbt scheduling from a single hourly dbt Cloud job to
  multiple jobs partitioned by model selector so a slow mart doesn't delay
  a fast one.
- **dbt**: models are already incremental (not full-refresh), so dbt's own
  cost scales with the size of each new batch, not total historical volume
  — the main lever at 10,000x is warehouse size/concurrency above, not
  rewriting the SQL.
