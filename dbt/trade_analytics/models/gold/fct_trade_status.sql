{{
  config(
    materialized='view',
    grants={'select': ['TRADE_ANALYTICS_COMPLIANCE', 'TRADE_ANALYTICS_ANALYST', 'ACCOUNTADMIN']},
    post_hook=[
      "alter view {{ this }} modify column notional set masking policy " ~ target.database ~ ".gold.mask_notional",
      "alter view {{ this }} modify column notional_usd set masking policy " ~ target.database ~ ".gold.mask_notional",
      "alter view {{ this }} modify column counterparty set masking policy " ~ target.database ~ ".gold.mask_counterparty",
    ]
  )
}}

-- Rule 4 ("mark trades as expired if the maturity date has passed") is
-- implemented as a computed column rather than a periodic UPDATE: a trade's
-- expiry is purely a function of maturity_date vs. today, so recomputing it
-- on read is always correct and needs no scheduled mutation job. At very
-- high row counts, swap this for a Dynamic Table or a clustered/materialized
-- table refreshed on a schedule (see docs/SCALABILITY.md).
--
-- notional_usd demonstrates the convert_to_usd() macro (macros/convert_to_usd.sql):
-- one line here instead of a hand-written 6-branch CASE, with the FX table
-- itself living in a single dbt_project.yml var.
--
-- RBAC + masking: this is one of only two GOLD objects (with
-- rpt_trade_report) TRADE_ANALYTICS_ANALYST is granted SELECT on -- see
-- the grants= override above and macros/create_masking_policies.sql. The
-- underlying fct_valid_trades stays COMPLIANCE-only, so masking here can't
-- be bypassed by querying the source table directly.

select
    trade_id,
    version,
    product_key,
    product_type,
    counterparty_key,
    counterparty,
    trader_key,
    trader,
    book_key,
    book,
    currency_key,
    currency,
    notional,
    {{ convert_to_usd('notional', 'currency') }} as notional_usd,
    price,
    trade_date,
    trade_date_key,
    maturity_date,
    maturity_date_key,
    case
        when maturity_date < current_date() then 'EXPIRED'
        else 'ACTIVE'
    end as trade_status,
    processed_at
from {{ ref('fct_valid_trades') }}
