{{
  config(
    materialized='incremental',
    on_schema_change='append_new_columns',
    transient=true,
    full_refresh=false
  )
}}

-- transient=true is dbt-snowflake's default for table/incremental models
-- anyway (no Fail-safe storage) -- made explicit here on purpose: this
-- table is a pure function of BRONZE.TRADES_RAW (permanent) plus this SQL,
-- so if it were ever lost, `dbt run` regenerates it exactly. Fail-safe's
-- extra 7-day recovery window would be cost with no real benefit. Contrast
-- with fct_rejected_trades / valid_trades_snapshot, which are explicitly
-- permanent for the opposite reason.

-- Selecting from the stream here, as the final statement dbt wraps into an
-- INSERT, is what consumes it and advances its offset in Snowflake. Every
-- dbt run (incremental or first-run full build) drains whatever the stream
-- currently holds, so no separate watermark is needed at this layer.
--
-- full_refresh=false is load-bearing, not stylistic: a --full-refresh here
-- would TRUNCATE this table and rebuild it from "whatever the stream
-- currently holds" -- but a stream only holds *unconsumed* changes, not
-- history, so any full-refresh after the stream has already been drained
-- by earlier normal runs silently and permanently discards everything
-- processed before that point (recoverable only because BRONZE.TRADES_RAW,
-- the append-only source table, is untouched by this -- this happened
-- live in this project and was recovered by rebuilding this table directly
-- from BRONZE.TRADES_RAW instead of the stream, then full-refreshing
-- int_trades_evaluated onward, which read from this table, not the
-- stream, and are safe to full-refresh). This config makes dbt ignore
-- --full-refresh for this model specifically, even when passed at the
-- project level -- the only correct way to rebuild it is the recovery
-- path above, deliberately, not as a side effect of an unrelated
-- full-refresh elsewhere.

with source as (

    select
        raw_payload,
        file_name,
        loaded_at
    from {{ source('bronze', 'trades_raw_stream') }}
    where metadata$action = 'INSERT'

)

select
    raw_payload:trade_id::string             as trade_id,
    raw_payload:version::number               as version,
    raw_payload:message_id::string            as message_id,
    raw_payload:source_system::string         as source_system,
    raw_payload:event_timestamp::timestamp_tz as event_timestamp,
    raw_payload:trade_date::date              as trade_date,
    raw_payload:maturity_date::date           as maturity_date,
    raw_payload:product_type::string          as product_type,
    raw_payload:counterparty::string          as counterparty,
    raw_payload:trader::string                as trader,
    raw_payload:book::string                  as book,
    raw_payload:currency::string              as currency,
    raw_payload:notional::float               as notional,
    raw_payload:price::float                  as price,
    file_name,
    loaded_at
from source
