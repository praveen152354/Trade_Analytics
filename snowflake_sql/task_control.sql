-- =============================================================================
-- Trade Analytics — Task Start/Stop Commands
-- =============================================================================
-- Suspend/resume every scheduled Snowflake object in this project. Use this
-- to stop the pipeline (no more credit burn, no more rows generated) when
-- you're not actively using it, and resume it when you are.
--
-- Run as ACCOUNTADMIN (or a role with OPERATE on the tasks/alert — the
-- TRADE_ANALYTICS_LOADER/TRANSFORMER roles aren't granted that by default).
-- See the note at the bottom on how this interacts with `terraform apply`.
-- =============================================================================


-- =============================================================================
-- STOP EVERYTHING
-- =============================================================================

alter task trade_analytics.bronze.ingest_trades_task suspend;
alter task trade_analytics.bronze.generate_trade_files_task suspend;
alter task trade_analytics.bronze.ingest_fx_rates_task suspend;

-- Optional: the failure alert has nothing to alert on once all tasks are
-- suspended (they can't fail if they're not running), but it still fires
-- its own check every 15 min for as long as it's enabled. Suspend it too
-- if you want zero scheduled activity at all:
alter alert trade_analytics.bronze.task_failure_alert suspend;


-- =============================================================================
-- START EVERYTHING
-- =============================================================================

alter task trade_analytics.bronze.generate_trade_files_task resume;
alter task trade_analytics.bronze.ingest_trades_task resume;
alter task trade_analytics.bronze.ingest_fx_rates_task resume;
alter alert trade_analytics.bronze.task_failure_alert resume;


-- =============================================================================
-- STATUS CHECK
-- =============================================================================

show tasks in schema trade_analytics.bronze;
select "name", "state", "schedule" from table(result_scan(last_query_id()));

show alerts in schema trade_analytics.bronze;
select "name", "state" from table(result_scan(last_query_id()));


-- =============================================================================
-- STOP / START ONE OBJECT AT A TIME
-- =============================================================================

-- alter task trade_analytics.bronze.generate_trade_files_task suspend;
-- alter task trade_analytics.bronze.generate_trade_files_task resume;

-- alter task trade_analytics.bronze.ingest_trades_task suspend;
-- alter task trade_analytics.bronze.ingest_trades_task resume;

-- alter task trade_analytics.bronze.ingest_fx_rates_task suspend;
-- alter task trade_analytics.bronze.ingest_fx_rates_task resume;

-- alter alert trade_analytics.bronze.task_failure_alert suspend;
-- alter alert trade_analytics.bronze.task_failure_alert resume;


-- =============================================================================
-- NOTE on Terraform
-- =============================================================================
-- terraform/orchestration.tf declares each task's `started` value explicitly:
-- GENERATE_TRADE_FILES_TASK and INGEST_TRADES_TASK are currently
-- `started = false` (intentionally suspended for cost, matching reality as
-- of the last apply); INGEST_FX_RATES_TASK is `started = true` (new, once-
-- daily, low cost). If you suspend/resume something here via SQL and it
-- doesn't match the `started` value in the .tf file, the next
-- `terraform apply` — even for an unrelated change — will silently flip it
-- back to match the config. Keep the two in sync: update `started` in
-- terraform/orchestration.tf (and re-apply) for anything you want to
-- survive a future apply; use the SQL above for a quick, temporary
-- start/stop you'll manage by hand.
