{% macro create_masking_policies() %}
{#-
    Creates (idempotently) the two Snowflake masking policies this project
    uses for column-level data masking, run once at the start of every
    dbt invocation (see on-run-start in dbt_project.yml) so they exist
    before the post-hooks on fct_trade_status/rpt_trade_report try to
    attach them.

    Both policies key off CURRENT_ROLE(): TRADE_ANALYTICS_TRANSFORMER (dbt's
    own build role), TRADE_ANALYTICS_COMPLIANCE (the full-fidelity consumer
    role), and ACCOUNTADMIN see the real value; every other role -- notably
    TRADE_ANALYTICS_ANALYST -- sees a masked one. This is RBAC and masking
    working together deliberately: TRADE_ANALYTICS_ANALYST is only granted
    SELECT on the two views these policies are attached to (see the
    `grants` config on those models and in dbt_project.yml) -- it can't
    reach the underlying fact/dimension tables to bypass the mask.

    mask_notional rounds to the nearest $1M rather than nulling the value
    out entirely: an analyst can still see rough exposure size and do
    aggregate analysis, just not the exact deal size.

    mask_counterparty replaces the name with a deterministic pseudonym
    (same counterparty always -> same masked value) rather than a single
    generic label: an analyst can still group and count by counterparty
    without learning which one it actually is.
-#}
{% if execute %}

    {% set mask_notional_sql %}
        create masking policy if not exists {{ target.database }}.gold.mask_notional as (val float) returns float ->
            case
                when current_role() in ('TRADE_ANALYTICS_TRANSFORMER', 'TRADE_ANALYTICS_COMPLIANCE', 'ACCOUNTADMIN') then val
                else round(val, -6)
            end
    {% endset %}
    {% do run_query(mask_notional_sql) %}

    {% set mask_counterparty_sql %}
        create masking policy if not exists {{ target.database }}.gold.mask_counterparty as (val varchar) returns varchar ->
            case
                when current_role() in ('TRADE_ANALYTICS_TRANSFORMER', 'TRADE_ANALYTICS_COMPLIANCE', 'ACCOUNTADMIN') then val
                else 'CPTY_' || upper(substr(md5(val), 1, 6))
            end
    {% endset %}
    {% do run_query(mask_counterparty_sql) %}

{% endif %}
{% endmacro %}
