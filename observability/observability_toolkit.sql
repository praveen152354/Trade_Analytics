-- =============================================================================
-- Trade Analytics — Snowflake Observability & Operations Toolkit
-- =============================================================================
-- Ready-to-run reference queries for debugging, time travel, optimization,
-- and monitoring this project. Grouped by purpose; every query is either
-- runnable as-is against TRADE_ANALYTICS or a documented template (marked
-- <PLACEHOLDER>) for a value you fill in. Run as a role with visibility into
-- ACCOUNT_USAGE (ACCOUNTADMIN, or a role granted the SNOWFLAKE database's
-- IMPORTED PRIVILEGES) unless noted otherwise.
--
-- Sections:
--   1. Debugging pipeline failures
--   2. Time travel & UNDROP
--   3. Performance / cost optimization
--   4. Observability & monitoring (health dashboards)
--   5. Access, lineage & governance
--   6. Housekeeping
-- =============================================================================


-- =============================================================================
-- 1. DEBUGGING
-- =============================================================================

-- 1.1 Most recent failures across the whole pipeline (any query, last 24h).
-- INFORMATION_SCHEMA.QUERY_HISTORY is real-time (no ACCOUNT_USAGE latency),
-- but scoped to the session's warehouse/role — run this connected to
-- TRADE_ANALYTICS_WH.
select
    query_id,
    query_text,
    error_code,
    error_message,
    start_time,
    total_elapsed_time / 1000 as elapsed_seconds
from table(information_schema.query_history(
    dateadd('hour', -24, current_timestamp()), current_timestamp()
))
where execution_status = 'FAILED_WITH_ERROR'
order by start_time desc;

-- 1.2 Same, but account-wide and with more history (ACCOUNT_USAGE has up to
-- 45min-3hr latency, but covers every warehouse/user, not just this session).
select
    query_id,
    user_name,
    warehouse_name,
    query_text,
    error_code,
    error_message,
    start_time
from snowflake.account_usage.query_history
where execution_status = 'FAIL'
  and start_time > dateadd('day', -7, current_timestamp())
order by start_time desc
limit 100;

-- 1.3 Full text + execution plan for one specific failing query.
-- <PLACEHOLDER>: replace with a query_id from 1.1/1.2.
select *
from table(information_schema.query_history())
where query_id = '<QUERY_ID>';
-- For the graphical profile: Snowsight -> Activity -> Query History -> paste
-- the query_id into the search box, or use GET_QUERY_OPERATOR_STATS(query_id).
select *
from table(get_query_operator_stats('<QUERY_ID>'));

-- 1.4 GENERATE_TRADE_FILES_TASK / INGEST_TRADES_TASK run history + errors.
select
    name as task_name,
    state,
    scheduled_time,
    query_start_time,
    completed_time,
    error_code,
    error_message,
    graph_run_group_id
from table(information_schema.task_history(
    scheduled_time_range_start => dateadd('day', -3, current_timestamp())
))
where name in ('GENERATE_TRADE_FILES_TASK', 'INGEST_TRADES_TASK')
order by scheduled_time desc;

-- 1.5 Is either task currently suspended? (auto-suspends after 3 consecutive
-- failures — see terraform/orchestration.tf suspend_task_after_num_failures)
show tasks in schema trade_analytics.bronze;
select "name", "state", "last_suspended_reason"
from table(result_scan(last_query_id()))
where "state" != 'started';

-- 1.6 COPY INTO failures / partially-loaded files (malformed JSON, schema
-- drift, etc.) — INGEST_TRADES_TASK uses ON_ERROR = 'SKIP_FILE', so failures
-- here don't abort the load but are worth knowing about.
select
    file_name,
    status,
    row_count,
    row_parsed,
    error_count,
    first_error_message,
    last_load_time
from snowflake.account_usage.copy_history
where table_name = 'TRADES_RAW'
  and last_load_time > dateadd('day', -7, current_timestamp())
  and status != 'LOADED'
order by last_load_time desc;

-- 1.7 Is the stream stale? (a stale stream silently stops returning changes)
select system$stream_has_data('trade_analytics.bronze.trades_raw_stream') as has_pending_data;
describe stream trade_analytics.bronze.trades_raw_stream;
-- Check the "stale_after" column in the output above; if that timestamp is
-- in the past, the stream needs to be recreated (see docs/SCALABILITY.md).

-- 1.8 dbt Cloud run history via the same account (if you'd rather stay in
-- SQL): every model/test failure in the last 7 days.
select
    query_tag,
    query_text,
    error_message,
    start_time
from snowflake.account_usage.query_history
where query_tag ilike '%dbt%'
  and execution_status = 'FAIL'
  and start_time > dateadd('day', -7, current_timestamp())
order by start_time desc;

-- 1.9 Ad-hoc investigation using a TEMPORARY table -- the right tool for
-- "let me poke at this without leaving anything behind or granting myself
-- write access to a real schema." Session-scoped: it's visible only to this
-- session, and Snowflake drops it automatically when the session ends (no
-- 6.4-style manual cleanup needed, unlike the Time Travel clone in 2.6,
-- which is a real object other sessions can see until you drop it).
create or replace temporary table tmp_todays_rejects as
select trade_id, version, reject_reason, count(*) as message_count
from trade_analytics.gold.fct_rejected_trades
where logged_at::date = current_date()
group by 1, 2, 3;

-- Now iterate freely against it in the same session without re-scanning GOLD:
select reject_reason, count(*) from tmp_todays_rejects group by 1 order by 2 desc;
select * from tmp_todays_rejects where message_count > 1;
-- No DROP needed -- it disappears when this session closes.


-- =============================================================================
-- 2. TIME TRAVEL & UNDROP
-- =============================================================================

-- 2.1 See a table as of N minutes ago — e.g. to compare before/after a
-- suspect dbt run.
select *
from trade_analytics.gold.fct_valid_trades
at (offset => -60*30); -- 30 minutes ago

-- 2.2 See a table as of a specific timestamp.
select *
from trade_analytics.gold.fct_valid_trades
at (timestamp => '2026-08-27 12:00:00 -07:00'::timestamp_tz);

-- 2.3 See a table immediately before a specific statement (useful right
-- after a bad dbt run/merge you want to diff against).
select *
from trade_analytics.gold.fct_valid_trades
before (statement => '<QUERY_ID>');

-- 2.4 Diff current state against an hour ago (e.g. sanity-check how many
-- rows a suspicious run touched).
select trade_id, version
from trade_analytics.gold.fct_valid_trades
minus
select trade_id, version
from trade_analytics.gold.fct_valid_trades at (offset => -3600);

-- 2.5 Restore a dropped table (Time Travel retention window applies —
-- default 1 day on a trial account, see DATA_RETENTION_TIME_IN_DAYS).
-- undrop table trade_analytics.gold.fct_valid_trades;

-- 2.6 Clone a table (or the whole schema) at a point in time — cheap,
-- metadata-only, good for "what did GOLD look like before I broke it".
create table if not exists trade_analytics.gold.fct_valid_trades_clone_debug
clone trade_analytics.gold.fct_valid_trades
at (offset => -3600);
-- drop table trade_analytics.gold.fct_valid_trades_clone_debug; -- clean up after

-- 2.7 How much Time Travel retention does each table actually have?
select table_schema, table_name, retention_time
from trade_analytics.information_schema.tables
where table_schema in ('BRONZE', 'SILVER', 'GOLD');


-- =============================================================================
-- 3. PERFORMANCE / COST OPTIMIZATION
-- =============================================================================

-- 3.1 Warehouse credit burn over time — the first place to look if costs
-- creep up as trade volume grows (see docs/SCALABILITY.md "10,000x" section).
select
    warehouse_name,
    date_trunc('hour', start_time) as hour,
    sum(credits_used) as credits_used
from snowflake.account_usage.warehouse_metering_history
where warehouse_name = 'TRADE_ANALYTICS_WH'
  and start_time > dateadd('day', -7, current_timestamp())
group by 1, 2
order by 2 desc;

-- 3.2 Queries queued waiting for warehouse capacity — a sign the warehouse
-- is undersized or single-clustered under concurrent load.
select
    query_id,
    query_text,
    queued_provisioning_time,
    queued_overload_time,
    execution_time
from snowflake.account_usage.query_history
where warehouse_name = 'TRADE_ANALYTICS_WH'
  and (queued_provisioning_time > 0 or queued_overload_time > 0)
  and start_time > dateadd('day', -1, current_timestamp())
order by start_time desc;

-- 3.3 Slowest queries in the last 24h — candidates for clustering keys or
-- query rewrites as GOLD tables grow.
select
    query_id,
    query_text,
    total_elapsed_time / 1000 as elapsed_seconds,
    bytes_scanned,
    partitions_scanned,
    partitions_total
from snowflake.account_usage.query_history
where warehouse_name = 'TRADE_ANALYTICS_WH'
  and start_time > dateadd('day', -1, current_timestamp())
order by total_elapsed_time desc
limit 20;

-- 3.4 Partition pruning efficiency for a specific table — low
-- partitions_scanned/partitions_total on a filtered query means pruning is
-- working; near-1.0 on a filtered query means it isn't (candidate for a
-- clustering key -- see 3.8, which already exists on fct_valid_trades,
-- fct_rejected_trades and BRONZE.TRADES_RAW).
select
    query_id,
    query_text,
    partitions_scanned,
    partitions_total,
    round(partitions_scanned / nullif(partitions_total, 0), 3) as scan_ratio
from snowflake.account_usage.query_history
where query_text ilike '%fct_valid_trades%'
  and start_time > dateadd('day', -1, current_timestamp())
order by start_time desc
limit 20;

-- 3.5 Result cache hit rate — free performance if queries repeat.
select
    count(*) as total_queries,
    count_if(bytes_scanned = 0 and execution_time = 0) as fully_cached,
    round(fully_cached / nullif(total_queries, 0) * 100, 1) as cache_hit_pct
from snowflake.account_usage.query_history
where warehouse_name = 'TRADE_ANALYTICS_WH'
  and start_time > dateadd('day', -1, current_timestamp());

-- 3.6 Table storage footprint (active + time-travel + fail-safe) — the
-- other side of Snowflake cost besides compute.
select
    table_schema,
    table_name,
    active_bytes / power(1024, 3) as active_gb,
    time_travel_bytes / power(1024, 3) as time_travel_gb,
    failsafe_bytes / power(1024, 3) as failsafe_gb
from snowflake.account_usage.table_storage_metrics
where table_catalog = 'TRADE_ANALYTICS'
  and deleted is null
order by active_bytes desc;

-- 3.7 Current warehouse config (size, auto-suspend, multi-cluster settings).
show warehouses like 'TRADE_ANALYTICS_WH';

-- 3.8 Clustering health for the three tables with an explicit clustering
-- key: fct_valid_trades / fct_rejected_trades (cluster_by=maturity_date, set
-- in their dbt config) and BRONZE.TRADES_RAW (cluster_by=to_date(loaded_at),
-- set in terraform/main.tf). average_depth close to 1 means well-clustered;
-- climbing over time as more data lands is the signal that re-clustering
-- (automatic, Snowflake-managed) is earning its keep. At this project's row
-- count these keys are illustrative -- Snowflake's automatic micro-
-- partitioning alone would perform fine without them.
select 'TRADE_ANALYTICS.GOLD.FCT_VALID_TRADES' as table_name,
       system$clustering_information('TRADE_ANALYTICS.GOLD.FCT_VALID_TRADES') as clustering_info
union all
select 'TRADE_ANALYTICS.GOLD.FCT_REJECTED_TRADES',
       system$clustering_information('TRADE_ANALYTICS.GOLD.FCT_REJECTED_TRADES')
union all
select 'TRADE_ANALYTICS.BRONZE.TRADES_RAW',
       system$clustering_information('TRADE_ANALYTICS.BRONZE.TRADES_RAW');


-- =============================================================================
-- 4. OBSERVABILITY & MONITORING (health dashboard queries)
-- =============================================================================

-- 4.1 One-glance pipeline health: last run of each scheduled object.
select 'GENERATE_TRADE_FILES_TASK' as object_name, max(scheduled_time) as last_run,
       max_by(state, scheduled_time) as last_state
from table(information_schema.task_history(
    scheduled_time_range_start => dateadd('day', -1, current_timestamp()),
    task_name => 'GENERATE_TRADE_FILES_TASK'
))
union all
select 'INGEST_TRADES_TASK', max(scheduled_time), max_by(state, scheduled_time)
from table(information_schema.task_history(
    scheduled_time_range_start => dateadd('day', -1, current_timestamp()),
    task_name => 'INGEST_TRADES_TASK'
));

-- 4.2 Task success rate over the last 7 days (SLA-style metric).
select
    name as task_name,
    count(*) as total_runs,
    count_if(state = 'SUCCEEDED') as succeeded,
    round(succeeded / nullif(total_runs, 0) * 100, 1) as success_pct
from table(information_schema.task_history(
    scheduled_time_range_start => dateadd('day', -7, current_timestamp())
))
where name in ('GENERATE_TRADE_FILES_TASK', 'INGEST_TRADES_TASK')
group by 1;

-- 4.3 Alert firing history — has TASK_FAILURE_ALERT actually triggered?
select *
from table(information_schema.alert_history(
    scheduled_time_range_start => dateadd('day', -7, current_timestamp())
))
where name = 'TASK_FAILURE_ALERT'
order by scheduled_time desc;

-- 4.4 Trade volume trend — rows landing per hour, a basic throughput metric.
select date_trunc('hour', loaded_at) as hour, count(*) as rows_loaded
from trade_analytics.bronze.trades_raw
group by 1
order by 1 desc
limit 48;

-- 4.5 Rejection rate over time — a data-quality trend line, not just a
-- point-in-time count.
select
    date_trunc('hour', logged_at) as hour,
    reject_reason,
    count(*) as rejects
from trade_analytics.gold.fct_rejected_trades
group by 1, 2
order by 1 desc;

-- 4.6 End-to-end freshness check: how far behind is GOLD from the raw feed?
select
    (select max(loaded_at) from trade_analytics.bronze.trades_raw) as latest_bronze_row,
    (select max(processed_at) from trade_analytics.gold.fct_valid_trades) as latest_gold_row,
    datediff('minute',
        (select max(processed_at) from trade_analytics.gold.fct_valid_trades),
        (select max(loaded_at) from trade_analytics.bronze.trades_raw)
    ) as gold_lag_minutes;

-- 4.7 Login/auth activity on the service user (useful if credentials are
-- ever suspected compromised or misconfigured).
select event_timestamp, user_name, client_ip, is_success, error_message
from snowflake.account_usage.login_history
where user_name = 'PRAVEENMS91'
  and event_timestamp > dateadd('day', -7, current_timestamp())
order by event_timestamp desc;


-- =============================================================================
-- 5. ACCESS, LINEAGE & GOVERNANCE
-- =============================================================================

-- 5.1 What privileges does each role actually have right now? (drift check
-- against terraform/main.tf's intended grants)
show grants to role trade_analytics_loader;
show grants to role trade_analytics_transformer;

-- 5.2 Who/what queried a specific table recently (requires ACCESS_HISTORY,
-- Enterprise edition+).
select query_id, user_name, query_start_time, direct_objects_accessed
from snowflake.account_usage.access_history
where query_start_time > dateadd('day', -1, current_timestamp())
  and direct_objects_accessed::string ilike '%FCT_VALID_TRADES%'
order by query_start_time desc
limit 20;

-- 5.3 Object dependency graph for a model — what would break if you dropped
-- or renamed it (handy before any future schema change like this one).
select referencing_object_name, referencing_object_domain,
       referenced_object_name, referenced_object_domain
from snowflake.account_usage.object_dependencies
where referenced_object_name = 'FCT_VALID_TRADES'
   or referencing_object_name = 'FCT_VALID_TRADES';


-- =============================================================================
-- 6. HOUSEKEEPING
-- =============================================================================

-- 6.1 Manually trigger a task run right now (don't wait for its schedule) —
-- handy while testing a change.
execute task trade_analytics.bronze.generate_trade_files_task;
execute task trade_analytics.bronze.ingest_trades_task;

-- 6.2 Resume a task that auto-suspended after repeated failures (fix the
-- root cause first — see section 1 — then resume).
-- alter task trade_analytics.bronze.generate_trade_files_task resume;
-- alter task trade_analytics.bronze.ingest_trades_task resume;

-- 6.3 Force-consume/reset the stream if it's ever stuck (last resort —
-- recreating it loses any un-consumed changes; only do this if you've
-- confirmed via 1.7 that the stream is genuinely stale, not just idle).
-- create or replace stream trade_analytics.bronze.trades_raw_stream
--   on table trade_analytics.bronze.trades_raw;

-- 6.4 Clean up ad-hoc debug clones so they don't accrue storage cost.
-- drop table if exists trade_analytics.gold.fct_valid_trades_clone_debug;
