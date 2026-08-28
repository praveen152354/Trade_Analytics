"""
Trade Analytics dashboard -- Pipeline Health page.

The "one place to see the whole pipeline end-to-end" view: live status for
every ingestion Task, the CDC stream, the failure alert, and a data-
freshness signal for the transform layer -- plus resume/suspend controls
for the ingestion Tasks and alert, right from the page. Replaces the value
an external orchestrator's UI would have given (see README's
"Orchestration" section for why a separate Airflow instance was built,
considered, and removed instead of kept for this).

Status logic lives in observability/pipeline_status.py, not here -- this
file is presentation only.
"""

from datetime import datetime, timezone

import streamlit as st

from pipeline_status import (
    get_alert_status,
    get_stream_backlog,
    get_task_status,
    get_transform_freshness,
    resume_alert,
    resume_task,
    suspend_alert,
    suspend_task,
)

st.set_page_config(page_title="Trade Analytics — Pipeline Health", layout="wide")
st.header("Trade Analytics — Pipeline Health")
st.caption(
    "Live status across the whole pipeline, Snowflake Tasks through the transform "
    "layer -- refreshes automatically every 30s, or click Refresh for this instant."
)

if st.button("🔄 Refresh now"):
    get_task_status.clear()
    get_alert_status.clear()
    get_stream_backlog.clear()
    get_transform_freshness.clear()
    st.rerun()

task_df = get_task_status()
alert = get_alert_status()
stream_has_backlog = get_stream_backlog()
freshness = get_transform_freshness()

task_state = {row["TASK"]: row for _, row in task_df.iterrows()}


def state_color(state: str) -> str:
    return {
        "started": "#1a7a3c",
        "suspended": "#a35a00",
    }.get((state or "").lower(), "#888")


def stage_box(icon: str, title: str, subtitle: str, color: str) -> str:
    return f"""
    <div style="flex:1; min-width:150px; border:2px solid {color}; border-radius:10px;
                padding:14px 10px; text-align:center; background:{color}0d;">
        <div style="font-size:32pt; line-height:1;">{icon}</div>
        <div style="font-weight:700; margin-top:6px; font-size:10.5pt;">{title}</div>
        <div style="font-size:8.8pt; color:#555; margin-top:2px;">{subtitle}</div>
    </div>
    """


arrow = '<div style="display:flex; align-items:center; font-size:18pt; color:#aaa; padding:0 4px;">&#8594;</div>'

gen_state = task_state.get("GENERATE_TRADE_FILES_TASK", {}).get("CURRENT_STATE", "unknown")
ingest_trades_state = task_state.get("INGEST_TRADES_TASK", {}).get("CURRENT_STATE", "unknown")
ingest_fx_state = task_state.get("INGEST_FX_RATES_TASK", {}).get("CURRENT_STATE", "unknown")

flow_html = f"""
<div style="display:flex; align-items:stretch; gap:2px; margin:14px 0; flex-wrap:wrap;">
    {stage_box("🏭", "Generate", "Snowpark proc -> stage", state_color(gen_state))}
    {arrow}
    {stage_box("📥", "Ingest Trades", "COPY INTO TRADES_RAW", state_color(ingest_trades_state))}
    {arrow}
    {stage_box("🌊", "Stream", "backlog: " + ("yes" if stream_has_backlog else "none"), "#a35a00" if stream_has_backlog else "#1a7a3c")}
    {arrow}
    {stage_box("🔧", "Transform (dbt)", "SILVER -> GOLD", "#1a7a3c" if freshness["last_valid_trade_processed"] else "#888")}
    {arrow}
    {stage_box("⭐", "Gold / Dashboard", "rpt_trade_report", "#1a7a3c")}
</div>
<div style="display:flex; align-items:stretch; gap:2px; margin:4px 0 18px 0; flex-wrap:wrap;">
    <div style="flex:1;"></div>
    <div style="flex:1;"></div>
    {stage_box("💱", "Ingest FX Rates", "COPY INTO FX_RATES_RAW", state_color(ingest_fx_state))}
    <div style="flex:1;"></div>
    <div style="flex:1;"></div>
    <div style="flex:1;"></div>
    <div style="flex:1;"></div>
</div>
"""
st.markdown(flow_html, unsafe_allow_html=True)

st.divider()

# --- Ingestion tasks: status + controls -------------------------------------
st.subheader("Ingestion Tasks")

TASK_LABELS = {
    "GENERATE_TRADE_FILES_TASK": ("🏭", "Trade generation", "every 2 min (configurable)"),
    "INGEST_TRADES_TASK": ("📥", "Trade ingestion", "every 5 min (configurable)"),
    "INGEST_FX_RATES_TASK": ("💱", "FX rate ingestion", "once daily"),
}

cols = st.columns(3)
for col, (task_name, (icon, label, cadence)) in zip(cols, TASK_LABELS.items()):
    row = task_state.get(task_name, {})
    current_state = row.get("CURRENT_STATE", "unknown")
    with col:
        st.markdown(f"**{icon} {label}**")
        st.caption(cadence)
        if current_state == "started":
            st.success("Running")
        else:
            st.warning("Suspended")
        last_state = row.get("LAST_RUN_STATE")
        last_completed = row.get("LAST_COMPLETED")
        if last_state:
            st.caption(f"Last run: {last_state}" + (f" at {last_completed}" if last_completed is not None else ""))
            if row.get("LAST_RUN_ERROR"):
                st.caption(f"⚠️ {row['LAST_RUN_ERROR']}")
        else:
            st.caption("No run history yet.")

        if current_state == "started":
            if st.button("⏸ Suspend", key=f"suspend_{task_name}"):
                suspend_task(task_name)
                st.rerun()
        else:
            if st.button("▶ Resume", key=f"resume_{task_name}"):
                st.session_state[f"confirm_{task_name}"] = True
            if st.session_state.get(f"confirm_{task_name}"):
                st.caption("⚠️ Resuming starts consuming warehouse credits on its schedule.")
                if st.button("Confirm resume", key=f"confirm_btn_{task_name}"):
                    resume_task(task_name)
                    st.session_state[f"confirm_{task_name}"] = False
                    st.rerun()

st.divider()

# --- Failure alert ------------------------------------------------------
st.subheader("Failure Alert")
alert_col1, alert_col2 = st.columns([3, 1])
with alert_col1:
    st.markdown("**🔔 TASK_FAILURE_ALERT**")
    st.caption(f"Checks TASK_HISTORY every 15 min, emails on any task failure. Schedule: {alert.get('schedule')}")
    if alert.get("state") == "started":
        st.success("Active")
    else:
        st.warning("Suspended")
with alert_col2:
    if alert.get("state") == "started":
        if st.button("⏸ Suspend alert"):
            suspend_alert()
            st.rerun()
    else:
        if st.button("▶ Resume alert"):
            resume_alert()
            st.rerun()

st.divider()

# --- Transform freshness --------------------------------------------------
st.subheader("Transform Layer Freshness")
st.caption(
    "Not a live dbt Cloud job-status check (that needs Snowflake External Access + "
    "a stored API token -- a separate decision) -- this shows when each GOLD/SILVER "
    "object was last actually updated, as a proxy for 'is dbt keeping up'."
)


def freshness_caption(ts):
    if ts is None:
        return "No data yet"
    now = datetime.now(timezone.utc)
    # dbt_updated_at (snapshot) comes back as a naive TIMESTAMP_NTZ (already
    # UTC, dbt's default); the other three columns are TIMESTAMP_LTZ and
    # come back tz-aware. Normalize both to UTC explicitly rather than
    # relying on astimezone()'s "assume system local time" behavior for
    # naive datetimes, which would silently misconvert on a non-UTC machine.
    ts_utc = ts.replace(tzinfo=timezone.utc) if ts.tzinfo is None else ts.astimezone(timezone.utc)
    age = now - ts_utc
    hours = age.total_seconds() / 3600
    if hours < 1:
        return f"{int(age.total_seconds() / 60)} min ago"
    return f"{hours:.1f} hours ago"


f1, f2, f3, f4 = st.columns(4)
f1.metric("Valid trades processed", freshness_caption(freshness["last_valid_trade_processed"]))
f2.metric("Rejected trades logged", freshness_caption(freshness["last_rejected_trade_logged"]))
f3.metric("FX rates loaded", freshness_caption(freshness["last_fx_rate_loaded"]))
f4.metric("Snapshot updated", freshness_caption(freshness["last_snapshot_update"]))
