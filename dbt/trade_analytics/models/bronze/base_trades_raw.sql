{{ config(materialized='view') }}

-- Thin passthrough over BRONZE.TRADES_RAW -- BRONZE does no transformation
-- by design (it's the raw, as-received landing layer; see
-- docs/VALIDATION_LOGIC.md). This model exists purely so BRONZE has a real,
-- visible node in dbt's model tree and lineage graph instead of only a
-- sources.yml stub with no queryable SQL.
--
-- Deliberately NOT used by stg_trades.sql, which continues to read
-- TRADES_RAW_STREAM directly via source() -- a stream only advances its
-- offset when read inside a committing DML statement, and stg_trades'
-- incremental insert is that statement. Routing it through an intermediate
-- view here would be, at best, redundant, and risks confusing which object
-- is the real consumer of the stream. This view is for browsability, not
-- part of the actual data path.

select *
from {{ source('bronze', 'trades_raw') }}
