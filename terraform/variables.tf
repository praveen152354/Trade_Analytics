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

variable "schemas" {
  description = "Schemas created under the database: raw landing, dbt staging/intermediate, and the analytics marts."
  type        = list(string)
  default     = ["RAW", "STAGING", "INTERMEDIATE", "ANALYTICS"]
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
