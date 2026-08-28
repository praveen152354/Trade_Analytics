"""
Trade Analytics dashboard -- Summary page (entry point).

Multi-page app: this file is "Summary" (high-level, small charts, one-line
dynamic explanations); pages/1_Trade_Details.py is "Trade Details"
(full table, per-trade Type 2 SCD history, rejected-trades audit). Shared
session/data/filter logic lives in common.py so both pages stay in sync.

Runs two ways with the same code -- see common.get_session():
  1. Natively inside Snowflake (Streamlit in Snowflake / SiS), deployed by
     terraform/streamlit.tf. The primary, "live" way to view it.
  2. Locally: `streamlit run dashboard/streamlit_app.py` (needs
     dashboard/requirements.txt and a populated .env).
"""

import plotly.express as px
import streamlit as st

from common import format_usd_compact, load_rejected_summary, load_report, render_filters

st.set_page_config(page_title="Trade Analytics — Summary", layout="wide")
st.header("Trade Analytics — Summary")

report_df = load_report()
rejected_summary_df = load_rejected_summary()

filtered_df = render_filters(report_df)

if filtered_df.empty:
    st.warning("No trades match the current filters.")
    st.stop()

# --- Narrative headline --------------------------------------------------
total_notional = filtered_df["NOTIONAL_USD"].sum()
active_count = int((filtered_df["TRADE_STATUS"] == "ACTIVE").sum())
active_pct = active_count / len(filtered_df) * 100
by_product = filtered_df.groupby("PRODUCT_TYPE")["NOTIONAL_USD"].sum().sort_values(ascending=False)
top_product, top_product_notional = by_product.index[0], by_product.iloc[0]
top_product_pct = top_product_notional / total_notional * 100 if total_notional else 0

st.markdown(
    # Dollar signs escaped (\$) -- Streamlit's markdown treats a pair of
    # unescaped $ as a LaTeX math span, which otherwise swallows everything
    # between the two amounts below into garbled math-mode rendering.
    f"**{len(filtered_df):,} trades** in view, worth **\\{format_usd_compact(total_notional)}** notional (USD) — "
    f"**{active_pct:.0f}% active**. **{top_product}** is the largest exposure by notional, "
    f"at \\{format_usd_compact(top_product_notional)} ({top_product_pct:.0f}%)."
)

# --- KPI row ---------------------------------------------------------------
c1, c2, c3, c4, c5 = st.columns(5)
c1.metric("Trades (filtered)", f"{len(filtered_df):,}")
c2.metric("Active", f"{active_count:,}")
c3.metric("Expired", f"{len(filtered_df) - active_count:,}")
c4.metric("Rejected (all-time)", f"{int(rejected_summary_df['REJECT_COUNT'].sum()):,}")
c5.metric("Notional (USD)", format_usd_compact(total_notional))

st.divider()

# --- 2x2 grid of small charts, each with a one-line dynamic caption -------
CHART_HEIGHT = 240

row1_left, row1_right = st.columns(2)
row2_left, row2_right = st.columns(2)

with row1_left:
    st.markdown("**Status**")
    status_counts = filtered_df["TRADE_STATUS"].value_counts().reset_index()
    status_counts.columns = ["status", "count"]
    fig = px.pie(status_counts, names="status", values="count", hole=0.55, height=CHART_HEIGHT)
    fig.update_layout(margin=dict(l=10, r=10, t=10, b=10), showlegend=True)
    st.plotly_chart(fig, use_container_width=True)
    st.caption(f"{active_pct:.0f}% active, {100 - active_pct:.0f}% expired.")

with row1_right:
    st.markdown("**Notional by product**")
    fig = px.bar(by_product.reset_index(), x="PRODUCT_TYPE", y="NOTIONAL_USD", height=CHART_HEIGHT)
    fig.update_layout(margin=dict(l=10, r=10, t=10, b=10), xaxis_title=None, yaxis_title=None)
    st.plotly_chart(fig, use_container_width=True)
    st.caption(f"{top_product} leads at \\{format_usd_compact(top_product_notional)} ({top_product_pct:.0f}% of total).")

with row2_left:
    st.markdown("**Notional by currency**")
    by_currency = filtered_df.groupby("CURRENCY")["NOTIONAL_USD"].sum().sort_values(ascending=False)
    top_currency, top_currency_notional = by_currency.index[0], by_currency.iloc[0]
    top_currency_pct = top_currency_notional / total_notional * 100 if total_notional else 0
    fig = px.bar(by_currency.reset_index(), x="CURRENCY", y="NOTIONAL_USD", height=CHART_HEIGHT)
    fig.update_layout(margin=dict(l=10, r=10, t=10, b=10), xaxis_title=None, yaxis_title=None)
    st.plotly_chart(fig, use_container_width=True)
    st.caption(f"{top_currency} dominates at {top_currency_pct:.0f}% of the book.")

with row2_right:
    st.markdown("**Rejections by reason**")
    if rejected_summary_df.empty:
        st.caption("No rejected trades recorded.")
    else:
        fig = px.bar(rejected_summary_df, x="REJECT_REASON", y="REJECT_COUNT", height=CHART_HEIGHT)
        fig.update_layout(margin=dict(l=10, r=10, t=10, b=10), xaxis_title=None, yaxis_title=None)
        st.plotly_chart(fig, use_container_width=True)
        top_reason = rejected_summary_df.iloc[0]
        reason_pct = top_reason["REJECT_COUNT"] / rejected_summary_df["REJECT_COUNT"].sum() * 100
        st.caption(f"{top_reason['REJECT_REASON']} is the top reason ({reason_pct:.0f}% of all rejects).")

st.divider()
st.page_link("pages/1_Trade_Details.py", label="Open Trade Details ->", icon="📄")
