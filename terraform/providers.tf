# Credentials are NOT set here. The provider reads them from environment
# variables at plan/apply time:
#   SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD (or
#   SNOWFLAKE_PRIVATE_KEY / SNOWFLAKE_PRIVATE_KEY_PATH for key-pair auth),
#   SNOWFLAKE_ROLE (should be a role with rights to create databases,
#   warehouses and roles — ACCOUNTADMIN or SYSADMIN+SECURITYADMIN on a trial
#   account).
# See ../.env.example.

provider "snowflake" {
  role = var.bootstrap_role
  # These resources are still preview features in provider v1.2.3.
  preview_features_enabled = [
    "snowflake_file_format_resource",
    "snowflake_stage_resource",
    "snowflake_table_resource",
    "snowflake_email_notification_integration_resource",
    "snowflake_procedure_python_resource",
    "snowflake_alert_resource",
    "snowflake_storage_integration_resource",
  ]
}
