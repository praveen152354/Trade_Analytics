# Streamlit in Snowflake (SiS): the dashboard runs natively inside Snowflake
# instead of on a local machine that has to stay running. No credentials or
# .env involved -- the app calls get_active_session() and reads GOLD
# directly, on TRADE_ANALYTICS_WH, viewable in Snowsight by anyone granted
# the transformer role.

resource "snowflake_stage" "dashboard_stage" {
  name     = "DASHBOARD_STAGE"
  database = snowflake_database.trade_analytics.name
  schema   = "GOLD"
  comment  = "Holds the Streamlit app file(s) for the trade dashboard. Content (streamlit_app.py, environment.yml) is PUT here outside Terraform -- same one deliberate exception as terraform/sql/generate_trade_files_procedure.sql."

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_streamlit" "dashboard" {
  name            = "TRADE_ANALYTICS_DASHBOARD"
  database        = snowflake_database.trade_analytics.name
  schema          = "GOLD"
  stage           = snowflake_stage.dashboard_stage.fully_qualified_name
  main_file       = "streamlit_app.py"
  query_warehouse = snowflake_warehouse.trade_analytics_wh.name
  title           = "Trade Analytics — Pipeline Overview"
  comment         = "Filterable trade report + rejection breakdown, reading rpt_trade_report / fct_rejected_trades. Source: dashboard/streamlit_app.py."

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
