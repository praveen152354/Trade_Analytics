# Streamlit in Snowflake (SiS): the dashboard runs natively inside Snowflake
# instead of on a local machine that has to stay running. No credentials or
# .env involved -- the app calls get_active_session() and reads GOLD
# directly, on TRADE_ANALYTICS_WH, viewable in Snowsight by anyone granted
# the transformer role.

resource "snowflake_stage" "dashboard_stage" {
  name     = "DASHBOARD_STAGE"
  database = snowflake_database.trade_analytics.name
  schema   = "GOLD"
  comment  = "Holds the Streamlit app file(s) for the trade dashboard. Content (Summary.py, common.py, pages/1_Trade_Details.py, environment.yml) is PUT here, the same pattern used for the GENERATE_TRADE_FILES procedure body."

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_streamlit" "dashboard" {
  name            = "TRADE_ANALYTICS_DASHBOARD"
  database        = snowflake_database.trade_analytics.name
  schema          = "GOLD"
  stage           = snowflake_stage.dashboard_stage.fully_qualified_name
  main_file       = "Summary.py"
  query_warehouse = snowflake_warehouse.trade_analytics_wh.name
  title           = "Trade Analytics"
  comment         = "Filterable trade report + rejection breakdown, reading rpt_trade_report / fct_rejected_trades. Source: dashboard/Summary.py."

  depends_on = [snowflake_stage.dashboard_stage]
}

resource "snowflake_grant_privileges_to_account_role" "transformer_dashboard_usage" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "STREAMLIT"
    object_name = snowflake_streamlit.dashboard.fully_qualified_name
  }
}

# A Streamlit app runs with its OWNER's rights, not the viewer's -- and the
# owner here is var.bootstrap_role (whichever role ran terraform apply),
# not the transformer role that actually owns the GOLD tables/views dbt
# builds. It needs SELECT on the GOLD objects it queries (rpt_trade_report,
# fct_rejected_trades), or it fails at query time with "Insufficient
# privileges... owner role <bootstrap_role> must have SELECT granted".
#
# That grant is NOT managed here in Terraform (a prior version of this file
# did, via "all"/"future" SELECT grants on GOLD) -- it's managed by dbt's
# own `grants` model config (dbt_project.yml + per-model config()), the
# same mechanism that grants TRADE_ANALYTICS_COMPLIANCE/ANALYST. Every GOLD
# object is dbt-managed, and dbt's grants are authoritative: it revokes any
# grant not in a model's declared list on every run. Managing the same
# grant from both Terraform AND dbt meant each run of one silently undid
# the other -- live-verified as the actual cause of the app breaking after
# a dbt run once ACCOUNTADMIN wasn't in dbt's declared grants list. dbt's
# `grants` config now includes ACCOUNTADMIN everywhere it needs to, and
# this is the one place that access is controlled.
