{{
  config(
    materialized='incremental',
    unique_key='message_id'
  )
}}

-- Compliance audit log: every message int_trades_evaluated turned away,
-- with the reason. Append-only, never mutated.

with rejected as (

    select *
    from {{ ref('int_trades_evaluated') }}
    where decision = 'REJECTED'
    {% if is_incremental() %}
    and evaluated_at > (
        select coalesce(max(logged_at), '{{ var("epoch_timestamp") }}'::timestamp_tz)
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
    existing_version,
    decision_reason as reject_reason,
    evaluated_at,
    current_timestamp() as logged_at
from rejected
