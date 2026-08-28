{{ config(materialized='table', transient=true) }}

-- Same pattern as dim_trader.sql -- see that file for the rationale.

with distinct_books as (

    select distinct book as book_name
    from {{ ref('int_trades_evaluated') }}
    where book is not null

)

select
    {{ dbt_utils.generate_surrogate_key(['book_name']) }} as book_key,
    book_name
from distinct_books
