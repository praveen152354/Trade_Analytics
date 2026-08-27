# Trade Analytics — Data Engineering Case Study

An end-to-end trade ETL pipeline: a mock trade feed is generated, loaded
into Snowflake, validated against version/maturity business rules in dbt,
split into valid/rejected tables for compliance, and orchestrated on a
schedule with Airflow.

```
data_generator/      mock trade feed + Snowflake loader (PUT + COPY INTO)
terraform/            IaC for all Snowflake objects (warehouse, db, schemas,
                       roles, stage, file format, raw table, stream)
dbt/trade_analytics/  staging -> business-rule evaluation -> valid/rejected marts
orchestration/airflow/ Docker Compose Airflow stack + the pipeline DAG
dashboard/             optional Streamlit trade-status dashboard
.github/workflows/     CI/CD for dbt and Terraform
docs/                  architecture diagram, setup guide, validation logic,
                        scalability/monitoring write-up
```

See **[docs/SETUP_GUIDE.md](docs/SETUP_GUIDE.md)** for step-by-step setup,
**[docs/VALIDATION_LOGIC.md](docs/VALIDATION_LOGIC.md)** for how each
business rule is implemented and why the stack is shaped this way, and
**[docs/SCALABILITY.md](docs/SCALABILITY.md)** for how the pipeline handles
failures, is monitored via Snowflake's admin views, and scales to 10,000x
volume. The architecture diagram source is
[docs/architecture.puml](docs/architecture.puml).

## Pipeline at a glance

```
generate_trades.py --> load_to_snowflake.py --> RAW.TRADES_RAW --(stream)-->
  dbt: stg_trades --> int_trades_evaluated --> valid_trades / rejected_trades --> trade_status
```

Business rules (all applied in `int_trades_evaluated`, see
[docs/VALIDATION_LOGIC.md](docs/VALIDATION_LOGIC.md) for detail):
1. Reject a trade with a version lower than the one already on file.
2. A same-version message replaces the existing row (merge on `trade_id`).
3. Reject a trade whose maturity date is already in the past.
4. A valid trade is marked `EXPIRED` once its maturity date passes
   (computed dynamically in the `trade_status` view).
5. Added rule: a trade superseded by a newer version within the same batch
   is logged as rejected rather than silently dropped.
6. Every rejection is written to `rejected_trades`, an append-only
   compliance audit log.

Airflow runs the whole chain every 30 minutes, retries failed tasks twice,
and emails on failure. See [docs/SCALABILITY.md](docs/SCALABILITY.md) for
the Snowflake `ACCOUNT_USAGE` queries and native Alerts used for pipeline
health monitoring independent of Airflow.
