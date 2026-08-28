"""
Shared session, data-loading, and filter logic for every page of the
multi-page dashboard (Summary.py = Summary, pages/*.py = Details).
Kept in one place so both pages query the same cached data and share the
same filter state across navigation (via st.session_state-backed widget
keys) instead of drifting or duplicating the connection logic.
"""

import os

import pandas as pd
import streamlit as st


def format_usd_compact(value: float) -> str:
    """$44,755,314,601 -> $44.76B -- KPI cards and inline captions have too
    little width for full-precision notional; the exact figure is still one
    click away in the Trade Details table."""
    sign = "-" if value < 0 else ""
    abs_value = abs(value)
    for threshold, suffix in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs_value >= threshold:
            return f"{sign}${abs_value / threshold:,.2f}{suffix}"
    return f"{sign}${abs_value:,.0f}"


@st.cache_resource
def get_session():
    try:
        from snowflake.snowpark.context import get_active_session

        return get_active_session()
    except Exception:
        from dotenv import load_dotenv
        from snowflake.snowpark import Session

        load_dotenv()
        return Session.builder.configs(
            {
                "account": os.environ["SNOWFLAKE_ACCOUNT"],
                "user": os.environ["SNOWFLAKE_USER"],
                "password": os.environ.get("SNOWFLAKE_PASSWORD"),
                "private_key_path": os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH") or None,
                "role": os.environ.get("SNOWFLAKE_TRANSFORMER_ROLE", "TRADE_ANALYTICS_TRANSFORMER"),
                "warehouse": os.environ.get("SNOWFLAKE_WAREHOUSE", "TRADE_ANALYTICS_WH"),
                "database": os.environ.get("SNOWFLAKE_DATABASE", "TRADE_ANALYTICS"),
                "schema": os.environ.get("SNOWFLAKE_TRANSFORM_SCHEMA", "GOLD"),
            }
        ).create()


@st.cache_data(ttl=60)
def load_report() -> pd.DataFrame:
    # rpt_trade_report is the flat, pre-joined reporting view (models/gold/rpt_trade_report.sql):
    # every filterable attribute is already a plain column, so this dashboard
    # never has to join dim_* tables itself.
    report = get_session().sql("SELECT * FROM RPT_TRADE_REPORT").to_pandas()
    # Snowpark's to_pandas() returns Snowflake DATE columns as plain
    # datetime.date objects (object dtype), not datetime64 -- normalize so
    # every comparison below behaves the same regardless of session path.
    report["TRADE_DATE"] = pd.to_datetime(report["TRADE_DATE"])
    report["MATURITY_DATE"] = pd.to_datetime(report["MATURITY_DATE"])
    return report


@st.cache_data(ttl=60)
def load_rejected_summary() -> pd.DataFrame:
    return get_session().sql(
        """
        SELECT reject_reason, count(*) as reject_count
        FROM FCT_REJECTED_TRADES
        GROUP BY reject_reason
        ORDER BY reject_count DESC
        """
    ).to_pandas()


@st.cache_data(ttl=60)
def load_rejected_detail() -> pd.DataFrame:
    return get_session().sql(
        """
        SELECT
            trade_id, version, trader, book, counterparty, product_type,
            currency, notional, price, trade_date, maturity_date,
            existing_version, reject_reason, logged_at
        FROM FCT_REJECTED_TRADES
        ORDER BY logged_at DESC
        """
    ).to_pandas()


@st.cache_data(ttl=60)
def load_trade_history(trade_id: str) -> pd.DataFrame:
    # valid_trades_snapshot is the Type 2 SCD history -- every recorded
    # version of a trade over time, one row per change dbt's monthly
    # snapshot job detected (snapshots/valid_trades_snapshot.sql).
    return get_session().sql(
        """
        SELECT
            version, product_type, counterparty, trader, book, currency,
            notional, price, trade_date, maturity_date,
            dbt_valid_from, dbt_valid_to
        FROM VALID_TRADES_SNAPSHOT
        WHERE trade_id = ?
        ORDER BY dbt_valid_from
        """,
        params=[trade_id],
    ).to_pandas()


def render_filters(report_df: pd.DataFrame) -> pd.DataFrame:
    """Sidebar filter widgets, state persisted via session_state keys so
    the same selections carry over when the user switches pages."""
    st.sidebar.header("Filters")

    def multiselect_filter(label: str, column: str, key: str):
        options = sorted(report_df[column].dropna().unique())
        st.session_state.setdefault(key, [])
        return st.sidebar.multiselect(label, options, key=key)

    trader_filter = multiselect_filter("Trader", "TRADER", "flt_trader")
    book_filter = multiselect_filter("Book", "BOOK", "flt_book")
    counterparty_filter = multiselect_filter("Counterparty", "COUNTERPARTY", "flt_counterparty")
    product_filter = multiselect_filter("Product type", "PRODUCT_TYPE", "flt_product")
    currency_filter = multiselect_filter("Currency", "CURRENCY", "flt_currency")
    st.session_state.setdefault("flt_status", [])
    status_filter = st.sidebar.multiselect(
        "Trade status", ["ACTIVE", "EXPIRED"], key="flt_status"
    )

    # setdefault() BEFORE creating the widget, then key= alone drives it --
    # no value= passed at all. Passing both value= and key= (even when
    # value is itself derived from session_state) is a documented Streamlit
    # anti-pattern that can fight with the widget's own state handling;
    # this is the pattern Streamlit's own docs recommend for a value that
    # must persist across reruns/pages.
    min_trade_date, max_trade_date = report_df["TRADE_DATE"].min(), report_df["TRADE_DATE"].max()
    st.session_state.setdefault("flt_trade_date", (min_trade_date, max_trade_date))
    trade_date_range = st.sidebar.date_input(
        "Trade (booking) date range",
        min_value=min_trade_date,
        max_value=max_trade_date,
        key="flt_trade_date",
    )

    # Note: this can never start earlier than today -- rule 3 rejects any
    # trade with an already-past maturity_date at submission, so no
    # currently-valid trade can have a maturity before today regardless of
    # how far in the past it was booked (see the "Trade (booking) date
    # range" filter above for that).
    min_date, max_date = report_df["MATURITY_DATE"].min(), report_df["MATURITY_DATE"].max()
    st.session_state.setdefault("flt_maturity", (min_date, max_date))
    maturity_range = st.sidebar.date_input(
        "Maturity date range",
        min_value=min_date,
        max_value=max_date,
        key="flt_maturity",
    )

    filtered = report_df.copy()
    if trader_filter:
        filtered = filtered[filtered["TRADER"].isin(trader_filter)]
    if book_filter:
        filtered = filtered[filtered["BOOK"].isin(book_filter)]
    if counterparty_filter:
        filtered = filtered[filtered["COUNTERPARTY"].isin(counterparty_filter)]
    if product_filter:
        filtered = filtered[filtered["PRODUCT_TYPE"].isin(product_filter)]
    if currency_filter:
        filtered = filtered[filtered["CURRENCY"].isin(currency_filter)]
    if status_filter:
        filtered = filtered[filtered["TRADE_STATUS"].isin(status_filter)]
    if isinstance(trade_date_range, tuple) and len(trade_date_range) == 2:
        start, end = trade_date_range
        filtered = filtered[
            (filtered["TRADE_DATE"] >= pd.Timestamp(start))
            & (filtered["TRADE_DATE"] <= pd.Timestamp(end))
        ]
    if isinstance(maturity_range, tuple) and len(maturity_range) == 2:
        start, end = maturity_range
        filtered = filtered[
            (filtered["MATURITY_DATE"] >= pd.Timestamp(start))
            & (filtered["MATURITY_DATE"] <= pd.Timestamp(end))
        ]

    return filtered
