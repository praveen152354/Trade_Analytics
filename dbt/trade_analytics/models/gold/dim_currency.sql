{{ config(materialized='table', transient=true) }}

-- Same pattern as dim_trader.sql -- see that file for the rationale.
-- Deliberately just the code, not a join to silver.fx_rates or the
-- fx_rates_to_usd var: this dimension answers "what currencies has this
-- project ever seen a trade in", not "what's today's rate" -- rate lookups
-- stay in convert_to_usd() (macros/convert_to_usd.sql), a separate concern.

with distinct_currencies as (

    select distinct currency as currency_code
    from {{ ref('int_trades_evaluated') }}
    where currency is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['currency_code']) }} as currency_key,
    currency_code
from distinct_currencies
