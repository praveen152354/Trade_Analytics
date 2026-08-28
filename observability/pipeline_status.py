"""
Live pipeline health checks + task controls for the Pipeline Health
dashboard page (dashboard/pages/2_Pipeline_Health.py).

Uploaded flat onto DASHBOARD_STAGE alongside common.py/Summary.py -- see
data_generator/../scratchpad upload script -- so it's importable there as
`from pipeline_status import ...`, the same pattern as `from common import
...`. Lives in its own observability/ folder in the repo (not dashboard/)
since it's a distinct concern: read-only status + operational controls
over the ingestion layer, not report rendering.

Every function here reuses common.get_session() rather than opening its
own connection, so it works identically inside Streamlit in Snowflake and
via the local Snowpark-session fallback.
"""

import pandas as pd
import streamlit as st

from common import get_session

# Every object this page watches/controls, and which schema it lives in.
TASKS = ["GENERATE_TRADE_FILES_TASK", "INGEST_TRADES_TASK", "INGEST_FX_RATES_TASK"]
TASK_SCHEMA = "BRONZE"
ALERT_NAME = "TASK_FAILURE_ALERT"


@st.cache_data(ttl=30)
def get_task_status() -> pd.DataFrame:
    """Current state (started/suspended) + most recent TASK_HISTORY row for
    every ingestion task, one row per task."""
    session = get_session()
    show_df = session.sql(f"SHOW TASKS IN SCHEMA {TASK_SCHEMA}").collect()
    state_by_name = {row["name"]: row["state"] for row in show_df}

    rows = []
    for task_name in TASKS:
        history = session.sql(
            f"""
            SELECT state, error_message, scheduled_time, completed_time, next_scheduled_time
            FROM TABLE(information_schema.task_history(task_name => ?))
            ORDER BY scheduled_time DESC
            LIMIT 1
            """,
            params=[task_name],
        ).collect()
        last = history[0] if history else None
        rows.append(
            {
                "TASK": task_name,
                "CURRENT_STATE": state_by_name.get(task_name, "UNKNOWN"),
                "LAST_RUN_STATE": last["STATE"] if last else None,
                "LAST_RUN_ERROR": last["ERROR_MESSAGE"] if last else None,
                "LAST_SCHEDULED": last["SCHEDULED_TIME"] if last else None,
                "LAST_COMPLETED": last["COMPLETED_TIME"] if last else None,
                "NEXT_SCHEDULED": last["NEXT_SCHEDULED_TIME"] if last else None,
            }
        )
    return pd.DataFrame(rows)


@st.cache_data(ttl=30)
def get_alert_status() -> dict:
    session = get_session()
    rows = session.sql(f"SHOW ALERTS IN SCHEMA {TASK_SCHEMA}").collect()
    for row in rows:
        if row["name"] == ALERT_NAME:
            return {"state": row["state"], "schedule": row["schedule"]}
    return {"state": "UNKNOWN", "schedule": None}


@st.cache_data(ttl=30)
def get_stream_backlog() -> bool:
    session = get_session()
    row = session.sql(
        "SELECT system$stream_has_data('BRONZE.TRADES_RAW_STREAM') AS has_data"
    ).collect()
    return bool(row[0]["HAS_DATA"])


@st.cache_data(ttl=30)
def get_transform_freshness() -> dict:
    """Not a live dbt Cloud job-status check (that needs Snowflake External
    Access + a stored API token -- a separate, bigger decision) -- this
    infers "is the transform layer keeping up" from data timestamps already
    in Snowflake: the newest row dbt's last successful run produced at each
    layer."""
    session = get_session()

    def scalar(sql):
        row = session.sql(sql).collect()
        return row[0][0] if row else None

    return {
        "last_valid_trade_processed": scalar(
            "SELECT MAX(processed_at) FROM GOLD.FCT_VALID_TRADES"
        ),
        "last_rejected_trade_logged": scalar(
            "SELECT MAX(logged_at) FROM GOLD.FCT_REJECTED_TRADES"
        ),
        "last_fx_rate_loaded": scalar(
            "SELECT MAX(loaded_at) FROM SILVER.FX_RATES"
        ),
        "last_snapshot_update": scalar(
            "SELECT MAX(dbt_updated_at) FROM GOLD.VALID_TRADES_SNAPSHOT"
        ),
    }


def resume_task(task_name: str):
    get_session().sql(f"ALTER TASK {TASK_SCHEMA}.{task_name} RESUME").collect()
    get_task_status.clear()


def suspend_task(task_name: str):
    get_session().sql(f"ALTER TASK {TASK_SCHEMA}.{task_name} SUSPEND").collect()
    get_task_status.clear()


def resume_alert():
    get_session().sql(f"ALTER ALERT {TASK_SCHEMA}.{ALERT_NAME} RESUME").collect()
    get_alert_status.clear()


def suspend_alert():
    get_session().sql(f"ALTER ALERT {TASK_SCHEMA}.{ALERT_NAME} SUSPEND").collect()
    get_alert_status.clear()
