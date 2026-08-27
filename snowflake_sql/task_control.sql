-- =============================================================================
-- Trade Analytics — Task Start/Stop Commands
-- =============================================================================
-- Suspend/resume every scheduled Snowflake object in this project. Use this
-- to stop the pipeline (no more credit burn, no more rows generated) when
-- you're not actively using it, and resume it when you are.
--
-- Run as ACCOUNTADMIN (or a role with OPERATE on the tasks/alert — the
-- TRADE_ANALYTICS_LOADER/TRANSFORMER roles aren't granted that by default).
-- These are also exactly what `terraform apply` will set STARTED = true for
-- both tasks back to on the next run — see the note at the bottom.
-- =============================================================================


-- =============================================================================
-- STOP EVERYTHING
-- =============================================================================

alter task trade_analytics.bronze.ingest_trades_task suspend;
alter task trade_analytics.bronze.generate_trade_files_task suspend;

-- Optional: the failure alert has nothing to alert on once both tasks are
-- suspended (they can't fail if they're not running), but it still fires
-- its own check every 15 min for as long as it's enabled. Suspend it too
-- if you want zero scheduled activity at all:
alter alert trade_analytics.bronze.task_failure_alert suspend;


-- =============================================================================
-- START EVERYTHING
-- =============================================================================

alter task trade_analytics.bronze.generate_trade_files_task resume;
alter task trade_analytics.bronze.ingest_trades_task resume;
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

-- alter alert trade_analytics.bronze.task_failure_alert suspend;
-- alter alert trade_analytics.bronze.task_failure_alert resume;


-- =============================================================================
-- NOTE on Terraform
-- =============================================================================
-- terraform/orchestration.tf declares both tasks with `started = true`. If
-- you stop them here via SQL and later run `terraform apply` for any
-- unrelated change, Terraform will see the drift (started: true in config
-- vs. suspended in reality) and resume both tasks as part of that apply —
-- even if you didn't intend to restart the pipeline. If you want the
-- suspended state to survive a stray `terraform apply`, change
-- `started = true` to `started = false` for both snowflake_task resources
-- in terraform/orchestration.tf and re-apply, then flip it back to `true`
-- (or just run the RESUME statements above) when you actually want it
-- running again.
