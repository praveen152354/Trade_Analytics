"""
Type 2 SCD snapshot of the trade book. Runs monthly, 01:00 UTC on the 1st
-- the same cadence dbt Cloud's "Month-End Snapshot" job used before its
schedule was disabled in favor of Airflow being the only trigger for
anything in this pipeline (see README's "Orchestration" section).

Deliberately its own DAG, not a step tacked onto trade_pipeline_dag.py's
hourly run: dbt's `check`-strategy snapshot only records a new row when a
tracked column actually changed, so it *could* safely run hourly as a
cheap no-op -- but "safe to run more often" isn't the same as "should":
this keeps the snapshot's own run history clean and matches its actual
purpose (a monthly, point-in-time compliance record), not noise mixed
into every hourly run.
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator

PROJECT_DIR = "/opt/airflow/project"
DBT_PROJECT_DIR = f"{PROJECT_DIR}/dbt/trade_analytics"

default_args = {
    "owner": "trade_analytics",
    "retries": 2,
    "retry_delay": timedelta(minutes=2),
}

with DAG(
    dag_id="trade_snapshot",
    description="Monthly Type 2 SCD snapshot of the trade book.",
    default_args=default_args,
    schedule_interval="0 1 1 * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["trade-analytics"],
) as dag:

    dbt_deps = BashOperator(
        task_id="dbt_deps",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt deps",
    )

    dbt_snapshot = BashOperator(
        task_id="dbt_snapshot",
        bash_command=f"cd {DBT_PROJECT_DIR} && dbt --no-partial-parse snapshot",
    )

    dbt_deps >> dbt_snapshot
