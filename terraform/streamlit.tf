# Streamlit in Snowflake (SiS): the dashboard runs natively inside Snowflake
# instead of on a local machine that has to stay running. No credentials or
# .env involved -- the app calls get_active_session() and reads GOLD
# directly, on TRADE_ANALYTICS_WH, viewable in Snowsight by anyone granted
# the transformer role.

resource "snowflake_stage" "dashboard_stage" {
  name     = "DASHBOARD_STAGE"
  database = snowflake_database.trade_analytics.name
  schema   = "GOLD"
  comment  = "Holds the Streamlit app file(s) for the trade dashboard. Content (Summary.py, common.py, pages/1_Trade_Details.py, environment.yml) is PUT here outside Terraform -- same one deliberate exception as terraform/sql/generate_trade_files_procedure.sql."

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
# builds. Without this, the app fails at query time with "Insufficient
# privileges... owner role <bootstrap_role> must have SELECT granted" even
# though the viewer's own role can already query GOLD fine. Both "all"
# (today's already-existing tables/views -- what the app needs immediately)
# and "future" (so a newly added dbt model works without a new grant) are
# needed; ON FUTURE alone does not retroactively cover existing objects.
resource "snowflake_grant_privileges_to_account_role" "bootstrap_gold_select_tables" {
  account_role_name = var.bootstrap_role
  privileges        = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.schemas["GOLD"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "bootstrap_gold_select_views" {
  account_role_name = var.bootstrap_role
  privileges        = ["SELECT"]
  on_schema_object {
    all {
      object_type_plural = "VIEWS"
      in_schema          = snowflake_schema.schemas["GOLD"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "bootstrap_gold_select_future_tables" {
  account_role_name = var.bootstrap_role
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.schemas["GOLD"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "bootstrap_gold_select_future_views" {
  account_role_name = var.bootstrap_role
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "VIEWS"
      in_schema          = snowflake_schema.schemas["GOLD"].fully_qualified_name
    }
  }
}
