{{ config(materialized='table', transient=true) }}

-- Same pattern as dim_trader.sql -- see that file for the rationale.
-- Kept as "product_type" (not renamed to "product_name") since that's the
-- term used everywhere else in this project (e.g. FX_SPOT, IRS, BOND).
--
-- The descriptive columns (asset_class, trade/maturity date meaning, notes)
-- come from seeds/product_reference.csv -- static reference data, not
-- something derived from trade messages, so it belongs in a seed rather
-- than int_trades_evaluated. Left join, not inner: a product_type the
-- generator starts emitting before the seed is updated for it still gets a
-- dimension row, just with null descriptive columns instead of silently
-- disappearing from the dimension.

with distinct_products as (

    select distinct product_type
    from {{ ref('int_trades_evaluated') }}
    where product_type is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['distinct_products.product_type']) }} as product_key,
    distinct_products.product_type,
    product_reference.product_name,
    product_reference.asset_class,
    product_reference.trade_date_meaning,
    product_reference.maturity_date_meaning,
    product_reference.notes
from distinct_products
left join {{ ref('product_reference') }} as product_reference
    on distinct_products.product_type = product_reference.product_type
