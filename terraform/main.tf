## Warehouse ##################################################################

resource "snowflake_warehouse" "trade_analytics_wh" {
  name                         = var.warehouse_name
  warehouse_size               = var.warehouse_size
  auto_suspend                 = var.warehouse_auto_suspend_seconds
  auto_resume                  = true
  initially_suspended          = true
  statement_timeout_in_seconds = 3600
}

## Database & schemas ##########################################################

resource "snowflake_database" "trade_analytics" {
  name    = var.database_name
  comment = "Trade ETL case study: raw trade landing, dbt staging/marts."
}

resource "snowflake_schema" "schemas" {
  for_each = toset(var.schemas)

  database     = snowflake_database.trade_analytics.name
  name         = each.value
  is_transient = false # matches the live value; leaving unset makes the provider force a destroy+recreate
}

## Roles ########################################################################

resource "snowflake_account_role" "loader" {
  name    = var.loader_role_name
  comment = "Used by the ingestion script (PUT + COPY INTO BRONZE.TRADES_RAW)."
}

resource "snowflake_account_role" "transformer" {
  name    = var.transformer_role_name
  comment = "Used by dbt to build staging/intermediate/mart models."
}

resource "snowflake_grant_account_role" "loader_to_user" {
  role_name = snowflake_account_role.loader.name
  user_name = var.grantee_user
}

resource "snowflake_grant_account_role" "transformer_to_user" {
  role_name = snowflake_account_role.transformer.name
  user_name = var.grantee_user
}

## Warehouse usage grants #######################################################

resource "snowflake_grant_privileges_to_account_role" "loader_warehouse_usage" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.trade_analytics_wh.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_warehouse_usage" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.trade_analytics_wh.name
  }
}

## Database usage grants ########################################################

resource "snowflake_grant_privileges_to_account_role" "loader_database_usage" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.trade_analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_database_usage" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.trade_analytics.name
  }
}

## Schema-level grants ##########################################################

# Loader only needs USAGE on BRONZE; the specific stage/table grants below cover DML.
resource "snowflake_grant_privileges_to_account_role" "loader_raw_schema_usage" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.schemas["BRONZE"].fully_qualified_name
  }
}

# Transformer (dbt) only needs to read BRONZE; it creates objects in SILVER/GOLD.
resource "snowflake_grant_privileges_to_account_role" "transformer_raw_schema_usage" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE", "CREATE VIEW"]
  on_schema {
    schema_name = snowflake_schema.schemas["BRONZE"].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_build_schema_usage" {
  for_each = toset([for s in var.schemas : s if s != "BRONZE"])

  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]
  on_schema {
    schema_name = snowflake_schema.schemas[each.value].fully_qualified_name
  }
}

# Transformer also needs SELECT on the BRONZE schema's landing table + stream
# (present and future — the stream created below counts as "future" at plan time).
resource "snowflake_grant_privileges_to_account_role" "transformer_raw_select" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_schema          = snowflake_schema.schemas["BRONZE"].fully_qualified_name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "transformer_raw_select_streams" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["SELECT"]
  on_schema_object {
    future {
      object_type_plural = "STREAMS"
      in_schema          = snowflake_schema.schemas["BRONZE"].fully_qualified_name
    }
  }
}

## Raw ingestion objects ########################################################

resource "snowflake_file_format" "trade_json_format" {
  name        = "TRADE_JSON_FORMAT"
  database    = snowflake_database.trade_analytics.name
  schema      = "BRONZE"
  format_type = "JSON"

  strip_outer_array = false

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_stage" "trades_stage" {
  name     = "TRADES_STAGE"
  database = snowflake_database.trade_analytics.name
  schema   = "BRONZE"
  comment  = "Internal stage trade batch files are PUT to before COPY INTO."

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_table" "trades_raw" {
  name            = "TRADES_RAW"
  database        = snowflake_database.trade_analytics.name
  schema          = "BRONZE"
  comment         = "Insert-only landing table for raw trade messages."
  change_tracking = true # required by the stream Snowflake auto-enabled this when TRADES_RAW_STREAM was created; must be declared or terraform will try to turn it back off.

  column {
    name = "RAW_PAYLOAD"
    type = "VARIANT"
  }
  column {
    name = "FILE_NAME"
    type = "VARCHAR"
  }
  column {
    name = "LOADED_AT"
    type = "TIMESTAMP_LTZ"
  }

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_stream_on_table" "trades_raw_stream" {
  name     = "TRADES_RAW_STREAM"
  database = snowflake_database.trade_analytics.name
  schema   = "BRONZE"
  table    = snowflake_table.trades_raw.fully_qualified_name
  comment  = "CDC stream consumed by dbt's stg_trades model."

  depends_on = [snowflake_table.trades_raw]
}

## Loader table/stage grants ####################################################

resource "snowflake_grant_privileges_to_account_role" "loader_table_dml" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["INSERT", "SELECT"]
  on_schema_object {
    object_type = "TABLE"
    object_name = snowflake_table.trades_raw.fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "loader_stage_usage" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["READ", "WRITE"]
  on_schema_object {
    object_type = "STAGE"
    object_name = snowflake_stage.trades_stage.fully_qualified_name
  }
}
