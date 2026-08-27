{{ config(materialized='view') }}

-- Rule 4 ("mark trades as expired if the maturity date has passed") is
-- implemented as a computed column rather than a periodic UPDATE: a trade's
-- expiry is purely a function of maturity_date vs. today, so recomputing it
-- on read is always correct and needs no scheduled mutation job. At very
-- high row counts, swap this for a Dynamic Table or a clustered/materialized
-- table refreshed on a schedule (see docs/SCALABILITY.md).

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
    case
        when maturity_date < current_date() then 'EXPIRED'
        else 'ACTIVE'
    end as trade_status,
    processed_at
from {{ ref('valid_trades') }}
