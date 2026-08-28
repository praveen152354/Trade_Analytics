"""
Optional visualization layer: a filterable trade report plus a pipeline
overview (active/expired/rejected), read straight from the GOLD marts.
Run with:

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
        schema=os.environ.get("SNOWFLAKE_TRANSFORM_SCHEMA", "GOLD"),
    )


@st.cache_data(ttl=60)
def load_data():
    conn = get_connection()
    # rpt_trade_report is the flat, pre-joined reporting view (models/gold/rpt_trade_report.sql):
    # every filterable attribute is already a plain column, so this dashboard
    # never has to join dim_* tables itself.
    report = pd.read_sql("SELECT * FROM RPT_TRADE_REPORT", conn)
    rejected = pd.read_sql(
        """
        SELECT reject_reason, count(*) as reject_count
        FROM FCT_REJECTED_TRADES
        GROUP BY reject_reason
        ORDER BY reject_count DESC
        """,
        conn,
    )
    return report, rejected


st.title("Trade Analytics — Pipeline Overview")

report_df, rejected_df = load_data()

# --- Filters (sidebar) -----------------------------------------------------
st.sidebar.header("Filters")


def multiselect_filter(label: str, column: str):
    options = sorted(report_df[column].dropna().unique())
    return st.sidebar.multiselect(label, options, default=[])


trader_filter = multiselect_filter("Trader", "TRADER")
book_filter = multiselect_filter("Book", "BOOK")
counterparty_filter = multiselect_filter("Counterparty", "COUNTERPARTY")
product_filter = multiselect_filter("Product type", "PRODUCT_TYPE")
currency_filter = multiselect_filter("Currency", "CURRENCY")
status_filter = st.sidebar.multiselect(
    "Trade status", ["ACTIVE", "EXPIRED"], default=[]
)

min_date, max_date = report_df["MATURITY_DATE"].min(), report_df["MATURITY_DATE"].max()
maturity_range = st.sidebar.date_input(
    "Maturity date range", value=(min_date, max_date), min_value=min_date, max_value=max_date
)

filtered_df = report_df.copy()
if trader_filter:
    filtered_df = filtered_df[filtered_df["TRADER"].isin(trader_filter)]
if book_filter:
    filtered_df = filtered_df[filtered_df["BOOK"].isin(book_filter)]
if counterparty_filter:
    filtered_df = filtered_df[filtered_df["COUNTERPARTY"].isin(counterparty_filter)]
if product_filter:
    filtered_df = filtered_df[filtered_df["PRODUCT_TYPE"].isin(product_filter)]
if currency_filter:
    filtered_df = filtered_df[filtered_df["CURRENCY"].isin(currency_filter)]
if status_filter:
    filtered_df = filtered_df[filtered_df["TRADE_STATUS"].isin(status_filter)]
if isinstance(maturity_range, tuple) and len(maturity_range) == 2:
    start, end = maturity_range
    filtered_df = filtered_df[
        (filtered_df["MATURITY_DATE"] >= pd.Timestamp(start))
        & (filtered_df["MATURITY_DATE"] <= pd.Timestamp(end))
    ]

# --- Summary -----------------------------------------------------------
col1, col2, col3, col4 = st.columns(4)
col1.metric("Trades (filtered)", len(filtered_df))
col2.metric("Active", int((filtered_df["TRADE_STATUS"] == "ACTIVE").sum()))
col3.metric("Expired", int((filtered_df["TRADE_STATUS"] == "EXPIRED").sum()))
col4.metric("Total notional (USD)", f"{filtered_df['NOTIONAL_USD'].sum():,.0f}")

left, right = st.columns(2)

with left:
    st.subheader("Trades by status")
    status_counts = filtered_df["TRADE_STATUS"].value_counts().reset_index()
    status_counts.columns = ["status", "count"]
    fig = px.pie(status_counts, names="status", values="count", hole=0.5)
    st.plotly_chart(fig, use_container_width=True)

with right:
    st.subheader("Notional (USD) by product type")
    by_product = filtered_df.groupby("PRODUCT_TYPE")["NOTIONAL_USD"].sum().reset_index()
    fig3 = px.bar(by_product, x="PRODUCT_TYPE", y="NOTIONAL_USD")
    st.plotly_chart(fig3, use_container_width=True)

st.subheader("Rejected trades by reason")
fig2 = px.bar(rejected_df, x="REJECT_REASON", y="REJECT_COUNT")
st.plotly_chart(fig2, use_container_width=True)

st.subheader(f"Trade report ({len(filtered_df)} rows)")
st.dataframe(filtered_df, use_container_width=True)

st.subheader("Rejected trades (audit)")
st.dataframe(rejected_df, use_container_width=True)
