{{
  config(
    materialized='incremental',
    on_schema_change='append_new_columns'
  )
}}

-- Selecting from the stream here, as the final statement dbt wraps into an
-- INSERT, is what consumes it and advances its offset in Snowflake. Every
-- dbt run (incremental or first-run full build) drains whatever the stream
-- currently holds, so no separate watermark is needed at this layer.

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
