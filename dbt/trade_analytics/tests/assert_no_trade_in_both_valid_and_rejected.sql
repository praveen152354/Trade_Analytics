-- A message rejected for being stale (rule 1) should always have a version
-- strictly lower than the trade's current accepted version — if one shows up
-- with version >= the current valid version, the version-comparison logic in
-- int_trades_evaluated has a bug. SUPERSEDED_IN_BATCH rejects are excluded on
-- purpose: a same-version duplicate arriving in one batch is expected to
-- share its version with the message that got accepted, so that case alone
-- doesn't indicate a defect.

select
    v.trade_id,
    v.version as valid_version,
    r.version as rejected_version,
    r.reject_reason
from {{ ref('fct_valid_trades') }} v
join {{ ref('fct_rejected_trades') }} r
    on v.trade_id = r.trade_id
where r.reject_reason = 'STALE_VERSION_LOWER_THAN_EXISTING'
  and r.version >= v.version
