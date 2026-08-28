{{ config(materialized='table', transient=true) }}

-- Same pattern as dim_trader.sql -- see that file for the rationale.
-- Kept as "product_type" (not renamed to "product_name") since that's the
-- term used everywhere else in this project (e.g. FX_SPOT, IRS, BOND).

with distinct_products as (

    select distinct product_type
    from {{ ref('int_trades_evaluated') }}
    where product_type is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['product_type']) }} as product_key,
    product_type
from distinct_products
