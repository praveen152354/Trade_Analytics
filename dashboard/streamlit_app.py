"""
Optional visualization layer: trade status breakdown (active/expired/rejected)
read straight from the ANALYTICS marts. Run with:

    streamlit run dashboard/streamlit_app.py
"""

import os

import pandas as pd
import plotly.express as px
import snowflake.connector
import streamlit as st
from dotenv import load_dotenv

load_dotenv()

st.set_page_config(page_title="Trade Analytics", layout="wide")


@st.cache_resource
def get_connection():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ.get("SNOWFLAKE_PASSWORD"),
        private_key_path=os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH") or None,
        role=os.environ.get("SNOWFLAKE_TRANSFORMER_ROLE", "TRADE_ANALYTICS_TRANSFORMER"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "TRADE_ANALYTICS_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "TRADE_ANALYTICS"),
        schema=os.environ.get("SNOWFLAKE_TRANSFORM_SCHEMA", "ANALYTICS"),
    )


@st.cache_data(ttl=60)
def load_data():
    conn = get_connection()
    trade_status = pd.read_sql("SELECT * FROM TRADE_STATUS", conn)
    rejected = pd.read_sql(
        """
        SELECT reject_reason, count(*) as reject_count
        FROM REJECTED_TRADES
        GROUP BY reject_reason
        ORDER BY reject_count DESC
        """,
        conn,
    )
    return trade_status, rejected


st.title("Trade Analytics — Pipeline Overview")

trade_status_df, rejected_df = load_data()

col1, col2, col3 = st.columns(3)
col1.metric("Valid trades", len(trade_status_df))
col2.metric("Active", int((trade_status_df["TRADE_STATUS"] == "ACTIVE").sum()))
col3.metric("Expired", int((trade_status_df["TRADE_STATUS"] == "EXPIRED").sum()))

left, right = st.columns(2)

with left:
    st.subheader("Valid trades by status")
    status_counts = trade_status_df["TRADE_STATUS"].value_counts().reset_index()
    status_counts.columns = ["status", "count"]
    fig = px.pie(status_counts, names="status", values="count", hole=0.5)
    st.plotly_chart(fig, use_container_width=True)

with right:
    st.subheader("Rejected trades by reason")
    fig2 = px.bar(rejected_df, x="REJECT_REASON", y="REJECT_COUNT")
    st.plotly_chart(fig2, use_container_width=True)

st.subheader("Valid trades")
st.dataframe(trade_status_df, use_container_width=True)

st.subheader("Rejected trades (audit)")
st.dataframe(rejected_df, use_container_width=True)
