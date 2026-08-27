{% macro generate_schema_name(custom_schema_name, node) -%}
    {#-
        dbt's default behaviour concatenates custom_schema_name onto the
        target/connection schema (e.g. "ANALYTICS_staging"). This project's
        schemas (RAW/STAGING/INTERMEDIATE/ANALYTICS) are pre-created by
        Terraform with exact names, so use the custom schema name verbatim
        when one is set, and fall back to the target schema otherwise.
    -#}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
