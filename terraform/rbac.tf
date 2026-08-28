# Read-only data-consumer roles, layered on top of the two service roles in
# main.tf (LOADER, TRANSFORMER). Column-level data masking is implemented in
# dbt (macros/create_masking_policies.sql, applied via an on-run-start hook
# and a post-hook on the two consumer-facing GOLD views) rather than here --
# Terraform's job stops at making these roles exist, granting them the
# schema access they need, and granting the transformer role permission to
# create masking policies; dbt owns the policy logic and which columns it's
# attached to, the same division of labor as the BRONZE passthrough views.
#
# Testing note: both new roles are granted to the same trial-account user
# as LOADER/TRANSFORMER/COMPLIANCE (var.grantee_user -- there's only one
# person here). Snowflake sessions default to secondary_roles = ALL, which
# combines every role granted to a user regardless of which one is set
# active -- so testing ANALYST's restrictions from that same user's session
# needs `USE SECONDARY ROLES NONE;` first, or the broader COMPLIANCE/
# TRANSFORMER grants will silently mask the restriction. In a real
# deployment each role would belong to a different person's login, so this
# wouldn't come up.

resource "snowflake_account_role" "analyst" {
  name    = var.analyst_role_name
  comment = "Read-only. Sees only the reporting views (rpt_trade_report, fct_trade_status), with sensitive columns masked via a dbt-managed Snowflake masking policy."
}

resource "snowflake_account_role" "compliance" {
  name    = var.compliance_role_name
  comment = "Read-only, full-fidelity. Sees everything in GOLD unmasked, including the rejected-trades audit log -- exempted from the masking policy by role name."
}

resource "snowflake_grant_account_role" "analyst_to_user" {
  role_name = snowflake_account_role.analyst.name
  user_name = var.grantee_user
}

resource "snowflake_grant_account_role" "compliance_to_user" {
  role_name = snowflake_account_role.compliance.name
  user_name = var.grantee_user
}

resource "snowflake_grant_privileges_to_account_role" "analyst_warehouse_usage" {
  account_role_name = snowflake_account_role.analyst.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.trade_analytics_wh.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "compliance_warehouse_usage" {
  account_role_name = snowflake_account_role.compliance.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "WAREHOUSE"
    object_name = snowflake_warehouse.trade_analytics_wh.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "analyst_database_usage" {
  account_role_name = snowflake_account_role.analyst.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.trade_analytics.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "compliance_database_usage" {
  account_role_name = snowflake_account_role.compliance.name
  privileges        = ["USAGE"]
  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.trade_analytics.name
  }
}

# USAGE on GOLD only -- neither consumer role has any reason to see BRONZE or
# SILVER, and dbt's own grants config (dbt_project.yml / model config) is
# what actually grants SELECT on individual GOLD objects, per role, per
# object -- not this schema-level grant.
resource "snowflake_grant_privileges_to_account_role" "analyst_gold_schema_usage" {
  account_role_name = snowflake_account_role.analyst.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.schemas["GOLD"].fully_qualified_name
  }
}

resource "snowflake_grant_privileges_to_account_role" "compliance_gold_schema_usage" {
  account_role_name = snowflake_account_role.compliance.name
  privileges        = ["USAGE"]
  on_schema {
    schema_name = snowflake_schema.schemas["GOLD"].fully_qualified_name
  }
}

# Lets dbt's on-run-start hook (macros/create_masking_policies.sql) create
# and own the masking policy objects it applies to rpt_trade_report /
# fct_trade_status.
resource "snowflake_grant_privileges_to_account_role" "transformer_gold_create_masking_policy" {
  account_role_name = snowflake_account_role.transformer.name
  privileges        = ["CREATE MASKING POLICY"]
  on_schema {
    schema_name = snowflake_schema.schemas["GOLD"].fully_qualified_name
  }
}
