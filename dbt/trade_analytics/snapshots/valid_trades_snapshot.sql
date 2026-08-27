{#-
    Type 2 SCD history of the trade book, via dbt's native snapshot feature.
    Every run that finds a tracked column changed for a trade_id closes out
    the current row (dbt_valid_to = now) and inserts a new one
    (dbt_valid_from = now), so the full version history of every trade is
    queryable rather than overwritten. dbt manages dbt_valid_from,
    dbt_valid_to, dbt_scd_id and dbt_updated_at automatically.

    This is invoked on a month-end schedule (see the "Month-End Snapshot"
    dbt Cloud job / docs/SETUP_GUIDE.md) to capture point-in-time,
    end-of-month positions for compliance/reporting — the same mechanism
    also works run-on-every-batch if intra-month history is ever needed;
    only the job's schedule would change, not this file.
-#}

{% snapshot valid_trades_snapshot %}

{{
    config(
        target_schema='gold',
        unique_key='trade_id',
        strategy='check',
        check_cols=[
            'version', 'maturity_date', 'notional', 'price', 'currency',
            'counterparty', 'trader', 'book', 'product_type',
        ],
    )
}}

select
    trade_id,
    version,
    product_type,
    counterparty,
    trader,
    book,
    currency,
    notional,
    price,
    trade_date,
    maturity_date,
    processed_at
from {{ ref('valid_trades') }}

{% endsnapshot %}
