variable "bootstrap_role" {
  description = "Role Terraform authenticates as. Needs rights to create databases, warehouses and roles."
  type        = string
  default     = "ACCOUNTADMIN"
}

variable "grantee_user" {
  description = "Existing Snowflake username to grant the loader and transformer roles to (your trial account login)."
  type        = string
}

variable "database_name" {
  type    = string
  default = "TRADE_ANALYTICS"
}

variable "warehouse_name" {
  type    = string
  default = "TRADE_ANALYTICS_WH"
}

variable "warehouse_size" {
  type    = string
  default = "XSMALL"
}

variable "warehouse_auto_suspend_seconds" {
  type    = number
  default = 60
}

variable "loader_role_name" {
  type    = string
  default = "TRADE_ANALYTICS_LOADER"
}

variable "transformer_role_name" {
  type    = string
  default = "TRADE_ANALYTICS_TRANSFORMER"
}

variable "analyst_role_name" {
  description = "Read-only, masked-data consumer role (reporting views only)."
  type        = string
  default     = "TRADE_ANALYTICS_ANALYST"
}

variable "compliance_role_name" {
  description = "Read-only, full-fidelity consumer role (all of GOLD, unmasked, including the rejected-trades audit log)."
  type        = string
  default     = "TRADE_ANALYTICS_COMPLIANCE"
}

variable "schemas" {
  description = "Medallion-architecture schemas: BRONZE (raw landing), SILVER (dbt staging + business-rule evaluation), GOLD (marts + Type-2 SCD snapshot)."
  type        = list(string)
  default     = ["BRONZE", "SILVER", "GOLD"]
}

## Orchestration (Snowflake-native: Snowpark proc + Tasks) ####################

variable "trades_per_generation" {
  description = "How many mock trade messages the generator writes per file."
  type        = number
  default     = 100
}

variable "trade_generation_schedule_minutes" {
  description = "How often the generation task writes a new batch file to the stage."
  type        = number
  default     = 2
}

variable "ingestion_schedule_minutes" {
  description = "How often the ingestion task runs COPY INTO to pull new files from the stage."
  type        = number
  default     = 5
}

variable "alert_email" {
  description = "Email address for task-failure alerts via a Snowflake email notification integration. Leave blank to skip creating it."
  type        = string
  default     = ""
}

## S3 -> Snowflake FX rates ingestion ###########################################

variable "aws_region" {
  description = "AWS region for the FX rates S3 bucket."
  type        = string
  default     = "eu-north-1"
}

variable "fx_rates_bucket_base_name" {
  description = "Base name for the FX rates S3 bucket; a random suffix is appended for global uniqueness."
  type        = string
  default     = "trade-analytics-fx-rates"
}

variable "fx_rates_ingestion_cron" {
  description = "Cron schedule (Snowflake TASK syntax, includes timezone) for polling S3 and loading new FX rate files. Default: once daily at 06:00 UTC."
  type        = string
  default     = "0 6 * * * UTC"
}
