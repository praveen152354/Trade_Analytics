{{
  config(
    materialized='incremental',
    unique_key='message_id',
    on_schema_change='append_new_columns'
  )
}}

-- Single decision point for every inbound trade message. Applies, in order:
--   1. Same-batch supersession: if two messages for the same trade_id land
--      in one run, only the highest version is a candidate; the rest are
--      logged as rejected (SUPERSEDED_IN_BATCH) rather than silently dropped.
--   2. Reject if maturity_date is already in the past (rule 3).
--   3. Reject if version is lower than the highest version ever accepted
--      for this trade_id (rule 1).
--   4. Otherwise accept — this covers both a brand new trade and a
--      same-version / higher-version message, which downstream valid_trades
--      merges in (replace-by-version, rule 2).
--
-- "Existing version" is looked up from this model's own accepted history
-- (self-reference via {{ this }}) rather than from valid_trades, so that
-- valid_trades can in turn depend on this model without creating a ref()
-- cycle. valid_trades' merged state and this model's accepted history are
-- always equivalent by construction.

with new_staged as (

    select *
    from {{ ref('stg_trades') }}
    {% if is_incremental() %}
    where loaded_at > (
        select coalesce(max(source_loaded_at), '{{ var("epoch_timestamp") }}'::timestamp_tz)
        from {{ this }}
    )
    {% endif %}

),

ranked_in_batch as (

    select
        *,
        row_number() over (
            partition by trade_id
            order by version desc, event_timestamp desc, loaded_at desc
        ) as rank_in_batch
    from new_staged

)

{% if is_incremental() %}
,

current_known_state as (

    select
        trade_id,
        max(version) as existing_version
    from {{ this }}
    where decision = 'ACCEPTED'
    group by trade_id

)
{% endif %}

,

joined as (

    select
        b.*
        {% if is_incremental() %}
        , k.existing_version
        {% else %}
        , cast(null as number) as existing_version
        {% endif %}
    from ranked_in_batch b
    {% if is_incremental() %}
    left join current_known_state k on b.trade_id = k.trade_id
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
    loaded_at as source_loaded_at,
    existing_version,
    case
        when rank_in_batch > 1 then 'REJECTED'
        when maturity_date < current_date() then 'REJECTED'
        when existing_version is not null and version < existing_version then 'REJECTED'
        else 'ACCEPTED'
    end as decision,
    case
        when rank_in_batch > 1 then 'SUPERSEDED_IN_BATCH'
        when maturity_date < current_date() then 'MATURITY_DATE_IN_PAST'
        when existing_version is not null and version < existing_version then 'STALE_VERSION_LOWER_THAN_EXISTING'
        when existing_version is not null and version = existing_version then 'REPLACED_SAME_VERSION'
        else 'NEW_TRADE_ACCEPTED'
    end as decision_reason,
    current_timestamp() as evaluated_at
from joined
