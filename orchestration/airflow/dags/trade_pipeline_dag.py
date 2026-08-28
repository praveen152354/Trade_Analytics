"""
End-to-end trade ETL pipeline. Runs hourly.

generate_trades -> load_to_snowflake -> dbt_deps -> dbt_run -> dbt_test

`dbt_run`/`dbt_test` are split so a failing test doesn't get reported as a
build failure and vice versa. On any task failure, Airflow emails
ALERT_EMAIL_TO (SMTP config in docker-compose.yml) and the DAG run shows
red in the UI for at-a-glance health monitoring.

The Type 2 SCD snapshot is a separate DAG (trade_snapshot_dag.py), run
monthly, not a step here -- see that file for why.
"""

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

PROJECT_DIR = "/opt/airflow/project"
DBT_PROJECT_DIR = f"{PROJECT_DIR}/dbt/trade_analytics"
ALERT_EMAIL_TO = [e.strip() for e in os.environ.get("ALERT_EMAIL_TO", "").split(",") if e.strip()]

default_args = {
    "owner": "trade_analytics",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
    "email_on_failure": bool(ALERT_EMAIL_TO),
    "email_on_retry": False,
    "email": ALERT_EMAIL_TO,
}

with DAG(
    dag_id="trade_pipeline",
    description="Simulate trades, load to Snowflake, validate with dbt.",
    default_args=default_args,
    schedule_interval="@hourly",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["trade-analytics"],
) as dag:

    generate_trades = BashOperator(
        task_id="generate_trades",
        bash_command=(
            f"python {PROJECT_DIR}/data_generator/generate_trades.py "
            f"--num-trades 500 "
            f"--out-dir {PROJECT_DIR}/data_generator/output"
        ),
    )

    load_to_snowflake = BashOperator(
        task_id="load_to_snowflake",
        bash_command=(
            f"python {PROJECT_DIR}/data_generator/load_to_snowflake.py "
            f'--file-glob "{PROJECT_DIR}/data_generator/output/*.jsonl"'
        ),
    )

    dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt deps",
    )

    # --no-partial-parse: dbt/trade_analytics/target/ (with its partial-parse
    # cache) is bind-mounted from the host, shared with local `dbt run`s on
    # the same project -- a cache built by one environment can go stale for
    # the other and crash with a KeyError during manifest loading. Costs a
    # few seconds of full reparse per run in exchange for not depending on
    # cache state from whichever environment touched target/ last.
    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt --no-partial-parse run",
    )

    dbt_test = BashOperator(
        task_id="dbt_test",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt --no-partial-parse test",
    )

    generate_trades >> load_to_snowflake >> dbt_deps >> dbt_run >> dbt_test
