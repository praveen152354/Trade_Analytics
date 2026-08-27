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
