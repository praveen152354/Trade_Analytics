{{
  config(
    materialized='incremental',
    unique_key='trade_id',
    incremental_strategy='merge'
  )
}}

-- One row per trade_id: the latest accepted version. A same-version message
-- (rule 2, "replace") and a higher-version amendment both merge in here via
-- the merge unique_key on trade_id; a lower version never reaches this model
-- because int_trades_evaluated already rejected it.

with accepted as (

    select *
    from {{ ref('int_trades_evaluated') }}
    where decision = 'ACCEPTED'
    {% if is_incremental() %}
    and evaluated_at > (
        select coalesce(max(processed_at), '{{ var("epoch_timestamp") }}'::timestamp_tz)
        from {{ this }}
    )
    {% endif %}

)

select
    trade_id,
    version,
    message_id,
    source_system,
    event_timestamp,
    trade_date,
    maturity_date,
    product_type,
    counterparty,
    trader,
    book,
    currency,
    notional,
    price,
    file_name,
    source_loaded_at,
    evaluated_at,
    current_timestamp() as processed_at
from accepted
