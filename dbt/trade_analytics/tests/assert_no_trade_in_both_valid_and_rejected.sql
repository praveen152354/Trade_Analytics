-- A message_id that was accepted should never also appear in the rejected
-- log, and a trade_id currently in valid_trades should never have its
-- *current* version sitting in rejected_trades. Returns offending rows;
-- dbt test passes when this returns zero rows.

select
    v.trade_id,
    v.version as valid_version,
    r.version as rejected_version,
    r.reject_reason
from {{ ref('valid_trades') }} v
join {{ ref('rejected_trades') }} r
    on v.trade_id = r.trade_id
    and v.version = r.version
