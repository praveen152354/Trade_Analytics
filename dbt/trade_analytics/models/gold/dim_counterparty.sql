{{ config(materialized='table', transient=true) }}

-- Same pattern as dim_trader.sql -- see that file for the rationale.

with distinct_counterparties as (

    select distinct counterparty as counterparty_name
    from {{ ref('int_trades_evaluated') }}
    where counterparty is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['counterparty_name']) }} as counterparty_key,
    counterparty_name
from distinct_counterparties
