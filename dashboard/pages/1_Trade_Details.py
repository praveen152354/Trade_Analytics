"""
Trade Analytics dashboard -- Trade Details page.

Full row-level table (same filters as Summary, shared via common.py's
session_state-backed widget keys), a per-trade amendment history drill-down
using the Type 2 SCD snapshot, and the rejected-trades audit log.
"""

import streamlit as st

from common import load_rejected_detail, load_report, load_trade_history, render_filters

st.set_page_config(page_title="Trade Analytics — Trade Details", layout="wide")
st.title("Trade Analytics — Trade Details")

report_df = load_report()
filtered_df = render_filters(report_df)

st.subheader(f"Trade report ({len(filtered_df):,} rows)")
st.caption("Same filters as the Summary page -- selections carry over between pages.")
st.dataframe(filtered_df, use_container_width=True, height=350)

st.divider()

# --- Per-trade amendment history (Type 2 SCD) ------------------------------
st.subheader("Trade history")
st.caption(
    "Pick a trade to see every version dbt's monthly Type 2 snapshot has "
    "recorded for it (snapshots/valid_trades_snapshot.sql)."
)

trade_options = sorted(filtered_df["TRADE_ID"].unique())
if not trade_options:
    st.caption("No trades match the current filters.")
else:
    selected_trade = st.selectbox("Trade ID", trade_options)
    history_df = load_trade_history(selected_trade)

    if history_df.empty:
        st.info(
            "No snapshot history yet for this trade -- the Type 2 snapshot runs "
            "monthly (1st, 01:00 UTC), so a trade created since the last run "
            "won't have a recorded version until the next one."
        )
    else:
        amendments = len(history_df) - 1
        current_row = history_df.iloc[-1]
        if amendments == 0:
            st.caption("1 recorded version -- no amendments since inception.")
        else:
            st.caption(
                f"{len(history_df)} recorded versions -- {amendments} amendment"
                f"{'s' if amendments != 1 else ''} since inception. "
                f"Currently version {int(current_row['VERSION'])}, "
                f"${current_row['NOTIONAL']:,.0f} {current_row['CURRENCY']}."
            )
        st.dataframe(
            history_df[
                [
                    "VERSION", "NOTIONAL", "PRICE", "CURRENCY", "MATURITY_DATE",
                    "COUNTERPARTY", "TRADER", "BOOK", "DBT_VALID_FROM", "DBT_VALID_TO",
                ]
            ],
            use_container_width=True,
        )

st.divider()

# --- Rejected trades audit ---------------------------------------------------
st.subheader("Rejected trades (audit)")
rejected_detail_df = load_rejected_detail()

reason_filter = st.multiselect(
    "Reject reason", sorted(rejected_detail_df["REJECT_REASON"].unique()), key="flt_reject_reason"
)
rd = rejected_detail_df
if reason_filter:
    rd = rd[rd["REJECT_REASON"].isin(reason_filter)]

st.caption(f"{len(rd):,} rejected message(s) shown, most recent first.")
st.dataframe(rd, use_container_width=True, height=350)
