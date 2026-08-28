{{ config(materialized='view') }}

-- Thin passthrough over BRONZE.FX_RATES_RAW -- BRONZE does no transformation
-- by design (it's the raw, as-received landing layer, including every
-- edited/re-uploaded file version -- see docs/VALIDATION_LOGIC.md).
--
-- Unlike base_trades_raw.sql, this one IS the actual source silver.fx_rates
-- reads from (via ref(), not source()) -- FX_RATES_RAW is a plain table
-- with no stream-consumption semantics to worry about, so routing through
-- here is a safe, idiomatic improvement: only this file ever references
-- the bronze source directly, and everything downstream depends on the
-- dbt model instead of reaching past it.
-- Git Push Test

select *
from {{ source('bronze', 'fx_rates_raw') }}
