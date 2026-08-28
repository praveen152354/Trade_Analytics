{{
  config(
    materialized='incremental',
    unique_key=['as_of_date', 'currency'],
    incremental_strategy='merge',
    on_schema_change='append_new_columns',
    transient=true
  )
}}

-- Deduplicates BRONZE.FX_RATES_RAW down to one row per (as_of_date, currency):
-- the most recently loaded value. BRONZE is deliberately left untouched and
-- append-only -- every file ever loaded is recorded there, even when a file
-- is edited and manually re-uploaded under the same name (Snowflake's COPY
-- INTO treats a changed file as new and loads it again rather than
-- overwriting -- see docs/VALIDATION_LOGIC.md). This model is what "removes
-- duplicates": querying it always returns exactly one, current rate per
-- date+currency, while BRONZE keeps the full history of what was ingested
-- and when, for audit.
--
-- Same merge-on-latest pattern as valid_trades.sql, just keyed on
-- (as_of_date, currency) instead of trade_id. Reads via ref() against
-- base_fx_rates_raw rather than source() directly -- the bronze passthrough
-- model is the single place that touches the raw source; everything
-- downstream depends on the dbt model instead of reaching past it.

with source as (

    select *
    from {{ ref('base_fx_rates_raw') }}
    {% if is_incremental() %}
    where loaded_at > (
        select coalesce(max(loaded_at), '{{ var("epoch_timestamp") }}'::timestamp_tz)
        from {{ this }}
    )
    {% endif %}

),

latest_per_day_and_currency as (

    select *
    from source
    qualify row_number() over (
        partition by as_of_date, currency
        order by loaded_at desc
    ) = 1

)

select
    as_of_date,
    currency,
    rate_to_usd,
    file_name,
    loaded_at
from latest_per_day_and_currency
