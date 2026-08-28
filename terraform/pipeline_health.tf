# Pipeline Health -- a standalone Streamlit in Snowflake app, separate
# from the Trade Analytics dashboard (streamlit.tf). Deliberately its own
# app rather than a third page there: this is an operational/observability
# tool (live Task/alert status, resume/suspend controls), a different
# audience and concern from the business-reporting dashboard.

resource "snowflake_stage" "pipeline_health_stage" {
  name     = "PIPELINE_HEALTH_STAGE"
  database = snowflake_database.trade_analytics.name
  schema   = "GOLD"
  comment  = "Holds the Pipeline Health app file(s) (Pipeline_Health.py, pipeline_status.py, environment.yml). Content is PUT here, the same pattern as GENERATE_TRADE_FILES' procedure body."

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_streamlit" "pipeline_health" {
  name            = "PIPELINE_HEALTH"
  database        = snowflake_database.trade_analytics.name
  schema          = "GOLD"
  stage           = snowflake_stage.pipeline_health_stage.fully_qualified_name
  main_file       = "Pipeline_Health.py"
  query_warehouse = snowflake_warehouse.trade_analytics_wh.name
  title           = "Pipeline Health"
  comment         = "Live end-to-end pipeline status (Tasks, alert, CDC stream, transform freshness) + resume/suspend controls. Source: observability/Pipeline_Health.py."

  depends_on = [snowflake_stage.pipeline_health_stage]
}

resource "snowflake_grant_privileges_to_account_role" "transformer_pipeline_health_usage" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_schema_object {
    object_type = "STREAMLIT"
    object_name = snowflake_streamlit.pipeline_health.fully_qualified_name
  }
}
