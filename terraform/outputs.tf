output "database_name" {
  value = snowflake_database.trade_analytics.name
}

output "warehouse_name" {
  value = snowflake_warehouse.trade_analytics_wh.name
}

output "loader_role" {
  value = snowflake_account_role.loader.name
}

output "transformer_role" {
  value = snowflake_account_role.transformer.name
}

output "raw_stage" {
  value = snowflake_stage_internal.trades_stage.fully_qualified_name
}

output "raw_stream" {
  value = snowflake_stream_on_table.trades_raw_stream.fully_qualified_name
}
