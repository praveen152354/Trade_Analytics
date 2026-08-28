{{ config(materialized='view') }}

-- The flat, report-ready object: one row per currently-valid trade, every
-- filterable business attribute already denormalized out (no joins needed
-- from a BI tool or the dashboard). Sits on top of the star schema rather
-- than replacing it -- fct_trade_status + the dim_* tables remain the
-- source of truth; this view exists purely so "trader = X and status =
-- ACTIVE and maturity between two dates" is a single flat WHERE clause.
-- A view, not a table: cheap to keep current given this project's volume,
-- and trade_status underneath already recomputes ACTIVE/EXPIRED on read.

select
    s.trade_id,
    s.version,
    s.trader,
    s.book,
    s.counterparty,
    s.product_type,
    s.currency,
    s.notional,
    s.notional_usd,
    s.price,
    s.trade_date,
    td.year          as trade_year,
    td.quarter       as trade_quarter,
    td.month_name    as trade_month_name,
    s.maturity_date,
    md.year          as maturity_year,
    md.quarter       as maturity_quarter,
    md.month_name    as maturity_month_name,
    datediff('day', current_date(), s.maturity_date) as days_to_maturity,
    s.trade_status,
    s.processed_at
from {{ ref('fct_trade_status') }} s
left join {{ ref('dim_date') }} td on s.trade_date = td.date_day
left join {{ ref('dim_date') }} md on s.maturity_date = md.date_day
