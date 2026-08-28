{{ config(materialized='table', transient=true) }}

-- Standard Kimball date dimension, built with dbt_utils.date_spine rather
-- than hand-written -- one row per calendar day across a range generous
-- enough to cover every trade_date (whenever the generator happened to
-- run) and every maturity_date (up to ~2 years out), configured via the
-- date_dim_start_date / date_dim_end_date vars in dbt_project.yml.

with spine as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('" ~ var('date_dim_start_date') ~ "' as date)",
        end_date="cast('" ~ var('date_dim_end_date') ~ "' as date)"
    ) }}

)

select
    to_number(to_char(date_day, 'YYYYMMDD')) as date_key,
    date_day,
    year(date_day)                           as year,
    quarter(date_day)                        as quarter,
    month(date_day)                          as month,
    monthname(date_day)                      as month_name,
    day(date_day)                            as day_of_month,
    dayname(date_day)                        as day_name,
    case when dayname(date_day) in ('Sat', 'Sun') then true else false end as is_weekend
from spine
