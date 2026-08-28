{{
  config(
    materialized='incremental',
    unique_key='trade_id',
    incremental_strategy='merge',
    transient=true,
    cluster_by=['maturity_date']
  )
}}

-- transient=true: current-state, fully re-derivable from BRONZE + this SQL,
-- so Fail-safe adds cost with no recovery benefit -- see stg_trades.sql.
-- cluster_by maturity_date: illustrative at this project's row count
-- (Snowflake's automatic micro-partitioning already handles a table this
-- small perfectly well) -- the real payoff shows up once this table is
-- large enough that reporting/dashboard queries filtering or ranging on
-- maturity_date (see rpt_trade_report.sql, the dashboard's date-range
-- filter) would otherwise have to scan most of the table's partitions.

-- One row per trade_id: the latest accepted version. A same-version message
-- (rule 2, "replace") and a higher-version amendment both merge in here via
-- the merge unique_key on trade_id; a lower version never reaches this model
-- because int_trades_evaluated already rejected it.
--
-- Joined out to the gold dimensions for surrogate-key foreign keys. The
-- natural-key text columns (trader, book, counterparty, product_type,
-- currency) are kept alongside the *_key columns -- a deliberate
-- denormalization for a handful of small, fixed-vocabulary codes, so a
-- simple query (or the convert_to_usd() macro, which needs a real currency
-- code) doesn't have to join every dimension just to read them.

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
    a.trade_id,
    a.version,
    a.message_id,
    a.source_system,
    a.event_timestamp,
    a.trade_date,
    td.date_key      as trade_date_key,
    a.maturity_date,
    md.date_key      as maturity_date_key,
    p.product_key,
    a.product_type,
    c.counterparty_key,
    a.counterparty,
    t.trader_key,
    a.trader,
    b.book_key,
    a.book,
    cur.currency_key,
    a.currency,
    a.notional,
    a.price,
    a.file_name,
    a.source_loaded_at,
    a.evaluated_at,
    current_timestamp() as processed_at
from accepted a
left join {{ ref('dim_product') }}      p   on a.product_type = p.product_type
left join {{ ref('dim_counterparty') }} c   on a.counterparty = c.counterparty_name
left join {{ ref('dim_trader') }}       t   on a.trader = t.trader_name
left join {{ ref('dim_book') }}         b   on a.book = b.book_name
left join {{ ref('dim_currency') }}     cur on a.currency = cur.currency_code
left join {{ ref('dim_date') }}         td  on a.trade_date = td.date_day
left join {{ ref('dim_date') }}         md  on a.maturity_date = md.date_day
