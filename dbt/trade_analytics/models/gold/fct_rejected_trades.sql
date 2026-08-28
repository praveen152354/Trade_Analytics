{{
  config(
    materialized='incremental',
    unique_key='message_id',
    transient=false,
    cluster_by=['maturity_date']
  )
}}

-- Compliance audit log: every message int_trades_evaluated turned away,
-- with the reason. Append-only, never mutated. Same dimension-join pattern
-- as fct_valid_trades.sql -- see that file for the rationale.
--
-- transient=false (permanent), deliberately different from every other
-- model in this project: this table isn't just "current state that's
-- cheap to recompute" -- it's a point-in-time record of what business
-- logic decided at the moment each message arrived. If dbt's rules ever
-- change later, replaying BRONZE would apply the *new* rules to *old*
-- messages and silently rewrite audit history. Permanent status buys the
-- extra 7-day Fail-safe recovery window a real compliance record deserves.
-- valid_trades_snapshot.sql makes the same choice for the same reason.

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
    r.trade_id,
    r.version,
    r.message_id,
    r.source_system,
    r.event_timestamp,
    r.trade_date,
    td.date_key      as trade_date_key,
    r.maturity_date,
    md.date_key      as maturity_date_key,
    p.product_key,
    r.product_type,
    c.counterparty_key,
    r.counterparty,
    t.trader_key,
    r.trader,
    b.book_key,
    r.book,
    cur.currency_key,
    r.currency,
    r.notional,
    r.price,
    r.file_name,
    r.source_loaded_at,
    r.existing_version,
    r.decision_reason as reject_reason,
    r.evaluated_at,
    current_timestamp() as logged_at
from rejected r
left join {{ ref('dim_product') }}      p   on r.product_type = p.product_type
left join {{ ref('dim_counterparty') }} c   on r.counterparty = c.counterparty_name
left join {{ ref('dim_trader') }}       t   on r.trader = t.trader_name
left join {{ ref('dim_book') }}         b   on r.book = b.book_name
left join {{ ref('dim_currency') }}     cur on r.currency = cur.currency_code
left join {{ ref('dim_date') }}         td  on r.trade_date = td.date_day
left join {{ ref('dim_date') }}         md  on r.maturity_date = md.date_day
