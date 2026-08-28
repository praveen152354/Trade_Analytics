{{ config(materialized='table', transient=true) }}

-- Small, fixed-vocabulary reference dimension. Rebuilt in full on every run
-- (cheap at this cardinality -- a handful of traders) so a newly-seen
-- trader shows up automatically, with no incremental/merge logic needed.
-- Sourced from int_trades_evaluated rather than the gold facts so a trader
-- who only ever appears on a rejected message still gets a row.

with distinct_traders as (

    select distinct trader as trader_name
    from {{ ref('int_trades_evaluated') }}
    where trader is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['trader_name']) }} as trader_key,
    trader_name
from distinct_traders
