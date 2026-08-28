# Snowflake-native orchestration: a Snowpark Python procedure generates mock
# trade batch files straight onto the internal stage (no external script,
# no Docker/Airflow), and two independently-scheduled Tasks drive the
# pipeline — one writes new files on its own cadence, the other polls the
# stage on a configurable interval and COPY INTOs whatever it finds. dbt
# run/test is scheduled separately, via dbt Cloud's own job scheduler.
#
# BRONZE.GENERATE_TRADE_FILES itself is defined in
# terraform/sql/generate_trade_files_procedure.sql, run once before `apply`
# — see docs/SETUP_GUIDE.md — rather than as a snowflake_procedure_python
# resource here, so its Python body stays under direct version control in
# its own file. Everything else here is Terraform-managed.

resource "snowflake_task" "generate_trade_files_task" {
  database  = snowflake_database.trade_analytics.name
  schema    = "BRONZE"
  name      = "GENERATE_TRADE_FILES_TASK"
  warehouse = snowflake_warehouse.trade_analytics_wh.name
  started   = false # intentionally suspended for now (cost) — flip to true + apply, or see snowflake_sql/task_control.sql, to resume
  comment   = "Writes a new mock trade batch file to BRONZE.TRADES_STAGE on a schedule."

  schedule {
    minutes = var.trade_generation_schedule_minutes
  }

  sql_statement = "CALL BRONZE.GENERATE_TRADE_FILES(${var.trades_per_generation})"

  suspend_task_after_num_failures = 3
  task_auto_retry_attempts        = 2
  # Tasks' error_integration only accepts cloud-messaging integrations
  # (SNS/Pub-Sub/Event Grid), not EMAIL — email alerting is done below via
  # a scheduled snowflake_alert that checks TASK_HISTORY instead.
  #
  # No depends_on for the procedure: it's created by
  # sql/generate_trade_files_procedure.sql, not by Terraform (see file header).
  # Run that script before the first `terraform apply`.
}

resource "snowflake_task" "ingest_trades_task" {
  database  = snowflake_database.trade_analytics.name
  schema    = "BRONZE"
  name      = "INGEST_TRADES_TASK"
  warehouse = snowflake_warehouse.trade_analytics_wh.name
  started   = false # intentionally suspended for now (cost) — flip to true + apply, or see snowflake_sql/task_control.sql, to resume
  comment   = "Polls BRONZE.TRADES_STAGE and COPY INTOs any new files. Runs on its own cadence, independent of generation."

  schedule {
    minutes = var.ingestion_schedule_minutes
  }

  sql_statement = <<-SQL
    COPY INTO BRONZE.TRADES_RAW (raw_payload, file_name, loaded_at)
    FROM (
        SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP()
        FROM @BRONZE.TRADES_STAGE
    )
    FILE_FORMAT = (FORMAT_NAME = 'BRONZE.TRADE_JSON_FORMAT')
    ON_ERROR = 'SKIP_FILE'
    PURGE = TRUE
  SQL

  suspend_task_after_num_failures = 3
  task_auto_retry_attempts        = 2
  # Tasks' error_integration only accepts cloud-messaging integrations
  # (SNS/Pub-Sub/Event Grid), not EMAIL — email alerting is done below via
  # a scheduled snowflake_alert that checks TASK_HISTORY instead.

  depends_on = [snowflake_table.trades_raw, snowflake_file_format.trade_json_format]
}

resource "snowflake_email_notification_integration" "trade_pipeline_alert" {
  count = var.alert_email != "" ? 1 : 0

  name               = "TRADE_PIPELINE_ALERT"
  enabled            = true
  allowed_recipients = [var.alert_email]
  comment            = "Email alert on ingestion task failure."
}

resource "snowflake_alert" "task_failure_alert" {
  count = var.alert_email != "" ? 1 : 0

  database  = snowflake_database.trade_analytics.name
  schema    = "BRONZE"
  name      = "TASK_FAILURE_ALERT"
  warehouse = snowflake_warehouse.trade_analytics_wh.name
  enabled   = true
  comment   = "Emails alert_email if any pipeline task failed in the last 15 minutes."

  alert_schedule {
    interval = 15
  }

  condition = <<-SQL
    select 1
    from table(information_schema.task_history(
        scheduled_time_range_start => dateadd('minute', -15, current_timestamp())
    ))
    where state = 'FAILED'
      and name in ('GENERATE_TRADE_FILES_TASK', 'INGEST_TRADES_TASK', 'INGEST_FX_RATES_TASK')
  SQL

  action = <<-SQL
    call system$send_email(
        '${snowflake_email_notification_integration.trade_pipeline_alert[0].name}',
        '${var.alert_email}',
        'Trade Analytics pipeline task failure',
        'One or more Snowflake tasks (GENERATE_TRADE_FILES_TASK / INGEST_TRADES_TASK / INGEST_FX_RATES_TASK) failed in the last 15 minutes. Check TASK_HISTORY for details.'
    )
  SQL

  depends_on = [snowflake_task.generate_trade_files_task, snowflake_task.ingest_trades_task, snowflake_task.ingest_fx_rates_task]
}
