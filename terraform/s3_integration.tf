resource "snowflake_storage_integration" "fx_rates" {
  name    = "FX_RATES_S3_INTEGRATION"
  comment = "Read-only access to s3://<bucket>/fx_rates/ for daily FX rate file ingestion."

  type                      = "EXTERNAL_STAGE"
  storage_provider          = "S3"
  enabled                   = true
  storage_aws_role_arn      = local.fx_rates_predicted_role_arn
  storage_allowed_locations = ["s3://${aws_s3_bucket.fx_rates.bucket}/fx_rates/"]
}

resource "snowflake_file_format" "fx_rates_csv" {
  name        = "FX_RATES_CSV_FORMAT"
  database    = snowflake_database.trade_analytics.name
  schema      = "BRONZE"
  format_type = "CSV"

  skip_header     = 1
  field_delimiter = ","

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_stage" "fx_rates_external" {
  name     = "FX_RATES_STAGE"
  database = snowflake_database.trade_analytics.name
  schema   = "BRONZE"
  comment  = "External stage over s3://<bucket>/fx_rates/ — manually-uploaded daily FX rate CSVs land here."

  url                 = "s3://${aws_s3_bucket.fx_rates.bucket}/fx_rates/"
  storage_integration = snowflake_storage_integration.fx_rates.name

  depends_on = [snowflake_schema.schemas]
}

resource "snowflake_table" "fx_rates_raw" {
  name     = "FX_RATES_RAW"
  database = snowflake_database.trade_analytics.name
  schema   = "BRONZE"
  comment  = "Daily FX rates ingested from S3. One row per (as_of_date, currency) per file loaded."

  column {
    name = "AS_OF_DATE"
    type = "DATE"
  }
  column {
    name = "CURRENCY"
    type = "VARCHAR"
  }
  column {
    name = "RATE_TO_USD"
    type = "FLOAT"
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

resource "snowflake_task" "ingest_fx_rates_task" {
  database  = snowflake_database.trade_analytics.name
  schema    = "BRONZE"
  name      = "INGEST_FX_RATES_TASK"
  warehouse = snowflake_warehouse.trade_analytics_wh.name
  started   = false # intentionally suspended for now (cost), same as the other two tasks — flip to true + apply, or see observability/task_control.sql, to resume
  comment   = "Once-daily COPY INTO from the S3 external stage — picks up whatever CSV(s) were manually uploaded to fx_rates/ since the last run."

  schedule {
    using_cron = var.fx_rates_ingestion_cron
  }

  sql_statement = <<-SQL
    COPY INTO BRONZE.FX_RATES_RAW (as_of_date, currency, rate_to_usd, file_name, loaded_at)
    FROM (
        SELECT $1, $2, $3, METADATA$FILENAME, CURRENT_TIMESTAMP()
        FROM @BRONZE.FX_RATES_STAGE
    )
    FILE_FORMAT = (FORMAT_NAME = 'BRONZE.FX_RATES_CSV_FORMAT')
    ON_ERROR = 'SKIP_FILE'
  SQL
  # No PURGE here (unlike the internal-stage trade ingestion): this bucket
  # is the user's own S3, the IAM policy is read-only (no s3:DeleteObject),
  # and deleting someone's manually-uploaded source files by default would
  # be a bad surprise. COPY INTO's own load history prevents the same file
  # being loaded twice, so leaving files in place is safe, not wasteful.

  suspend_task_after_num_failures = 3
  task_auto_retry_attempts        = 2

  depends_on = [snowflake_table.fx_rates_raw, snowflake_file_format.fx_rates_csv, snowflake_stage.fx_rates_external]
}
