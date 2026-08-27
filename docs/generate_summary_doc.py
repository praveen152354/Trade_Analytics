"""
Builds a standalone Word document summarizing the Snowflake objects
provisioned by Terraform and the scripts/files that make up the pipeline.
Run once, locally, to produce docs/Trade_Analytics_Summary.docx:

    pip install python-docx
    python docs/generate_summary_doc.py
"""

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.shared import Inches, Pt, RGBColor

NAVY = RGBColor(0x1B, 0x2A, 0x4A)
GREY = RGBColor(0x55, 0x55, 0x55)


def add_title(doc, text):
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.LEFT
    run = p.add_run(text)
    run.font.size = Pt(26)
    run.font.bold = True
    run.font.color.rgb = NAVY


def add_subtitle(doc, text):
    p = doc.add_paragraph()
    run = p.add_run(text)
    run.font.size = Pt(12)
    run.font.color.rgb = GREY


def add_h2(doc, text):
    h = doc.add_heading(text, level=2)
    for run in h.runs:
        run.font.color.rgb = NAVY


def add_table(doc, headers, rows, col_widths=None):
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Light Grid Accent 1"
    hdr_cells = table.rows[0].cells
    for i, h in enumerate(headers):
        hdr_cells[i].text = h
        for p in hdr_cells[i].paragraphs:
            for r in p.runs:
                r.font.bold = True
    for row in rows:
        cells = table.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = str(val)
    if col_widths:
        for row in table.rows:
            for i, w in enumerate(col_widths):
                row.cells[i].width = Inches(w)
    doc.add_paragraph()
    return table


def add_code_block(doc, code_text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(8)
    run = p.add_run(code_text)
    run.font.name = "Consolas"
    run.font.size = Pt(9)
    p_format = p.paragraph_format
    p_format.left_indent = Inches(0.25)


def build():
    doc = Document()

    # Base font
    style = doc.styles["Normal"]
    style.font.name = "Calibri"
    style.font.size = Pt(10.5)

    add_title(doc, "Trade Analytics — Provisioned Objects & Scripts")
    add_subtitle(doc, "Data Engineering Case Study — Snowflake + dbt + Airflow + Terraform")
    doc.add_paragraph()

    # ---------------------------------------------------------------
    add_h2(doc, "1. Snowflake objects created (via Terraform)")
    doc.add_paragraph(
        "All objects below were provisioned by terraform apply against the live "
        "trial account (database TRADE_ANALYTICS), using terraform/main.tf. "
        "27 resources total: warehouse, database, 4 schemas, 2 roles, 2 role "
        "grants, 16 privilege grants, 1 file format, 1 stage, 1 table, 1 stream."
    )

    add_table(
        doc,
        ["Object", "Type", "Schema", "Purpose"],
        [
            ["TRADE_ANALYTICS_WH", "Warehouse", "—", "XSMALL, auto-suspend 60s. Compute for both ingestion and dbt."],
            ["TRADE_ANALYTICS", "Database", "—", "Top-level container for the whole pipeline."],
            ["RAW", "Schema", "TRADE_ANALYTICS", "Landing zone: raw trade files, stage, stream."],
            ["STAGING", "Schema", "TRADE_ANALYTICS", "dbt staging models (stg_trades)."],
            ["INTERMEDIATE", "Schema", "TRADE_ANALYTICS", "dbt business-rule evaluation (int_trades_evaluated)."],
            ["ANALYTICS", "Schema", "TRADE_ANALYTICS", "dbt marts: valid_trades, rejected_trades, trade_status."],
            ["TRADE_ANALYTICS_LOADER", "Role", "—", "Used by the Python ingestion script (PUT + COPY INTO)."],
            ["TRADE_ANALYTICS_TRANSFORMER", "Role", "—", "Used by dbt to build every model."],
            ["TRADE_JSON_FORMAT", "File format", "RAW", "JSON, one object per line, used by COPY INTO."],
            ["TRADES_STAGE", "Internal stage", "RAW", "Trade batch files are PUT here before COPY INTO."],
            ["TRADES_RAW", "Table", "RAW", "Insert-only landing table (raw_payload VARIANT, file_name, loaded_at)."],
            ["TRADES_RAW_STREAM", "Stream", "RAW", "CDC stream on TRADES_RAW; consumed by dbt's stg_trades model."],
        ],
        col_widths=[1.6, 1.1, 1.1, 3.2],
    )

    doc.add_paragraph(
        "Both roles are granted to the account user PRAVEENMS91 and given USAGE on "
        "the warehouse/database. The transformer role additionally gets "
        "CREATE TABLE / CREATE VIEW on STAGING, INTERMEDIATE and ANALYTICS, and "
        "SELECT on all present-and-future tables/streams in RAW. The loader role "
        "is scoped narrowly to INSERT/SELECT on TRADES_RAW and READ/WRITE on "
        "TRADES_STAGE only."
    )

    doc.add_page_break()

    # ---------------------------------------------------------------
    add_h2(doc, "2. dbt models — business rules")
    add_table(
        doc,
        ["Model", "Materialization", "What it does"],
        [
            ["stg_trades", "incremental (append)", "Flattens raw JSON from the stream into typed columns."],
            ["int_trades_evaluated", "incremental (append)", "Single decision point: accepts or rejects each trade message and records why."],
            ["valid_trades", "incremental (merge on trade_id)", "One row per trade_id — the latest accepted version."],
            ["rejected_trades", "incremental (append)", "Compliance audit log of every rejected message + reason."],
            ["trade_status", "view", "valid_trades + a computed ACTIVE/EXPIRED column."],
        ],
        col_widths=[1.6, 1.8, 3.6],
    )

    add_table(
        doc,
        ["Rule", "Outcome"],
        [
            ["Lower version than existing", "REJECTED — reason STALE_VERSION_LOWER_THAN_EXISTING"],
            ["Same version as existing", "ACCEPTED — merges in, replacing the row"],
            ["Maturity date already in the past", "REJECTED — reason MATURITY_DATE_IN_PAST"],
            ["Maturity date passes after acceptance", "trade_status view marks it EXPIRED (computed, not mutated)"],
            ["Two versions of one trade in the same batch", "Highest version ACCEPTED; the other REJECTED as SUPERSEDED_IN_BATCH"],
            ["Any rejection", "Logged to rejected_trades — append-only audit trail"],
        ],
        col_widths=[3.5, 3.5],
    )

    doc.add_page_break()

    # ---------------------------------------------------------------
    add_h2(doc, "3. Repository layout & scripts")
    add_table(
        doc,
        ["Path", "Purpose"],
        [
            ["data_generator/generate_trades.py", "Simulates a batch of trade messages (new/amended/duplicate/stale/matured), writes .jsonl."],
            ["data_generator/load_to_snowflake.py", "PUTs the batch file to RAW.TRADES_STAGE, then COPY INTO RAW.TRADES_RAW."],
            ["terraform/*.tf", "IaC for every Snowflake object listed in section 1."],
            ["dbt/trade_analytics/models/staging/stg_trades.sql", "Consumes the RAW stream, flattens VARIANT to columns."],
            ["dbt/trade_analytics/models/intermediate/int_trades_evaluated.sql", "All business-rule logic (accept/reject + reason)."],
            ["dbt/trade_analytics/models/marts/valid_trades.sql", "Merge-incremental table of current accepted trades."],
            ["dbt/trade_analytics/models/marts/rejected_trades.sql", "Append-only rejected-trade audit log."],
            ["dbt/trade_analytics/models/marts/trade_status.sql", "View computing ACTIVE/EXPIRED status."],
            ["orchestration/airflow/docker-compose.yml + dags/trade_pipeline_dag.py", "Schedules generate -> load -> dbt run -> dbt test every 30 min; emails on failure."],
            ["dashboard/streamlit_app.py", "Optional Streamlit dashboard over trade_status and rejected_trades."],
            [".github/workflows/dbt_ci.yml, terraform_ci.yml", "CI/CD: dbt build/test on PR + merge; terraform fmt/validate/plan on PR, apply on manual dispatch."],
            ["docs/SETUP_GUIDE.md, VALIDATION_LOGIC.md, SCALABILITY.md", "Step-by-step setup, rule-by-rule rationale, and the failure-handling / monitoring / 10,000x-scale write-up."],
        ],
        col_widths=[3.6, 3.4],
    )

    doc.add_page_break()

    # ---------------------------------------------------------------
    add_h2(doc, "4. Pipeline flow")
    add_code_block(
        doc,
        "generate_trades.py\n"
        "      |\n"
        "      v\n"
        "load_to_snowflake.py  --(PUT + COPY INTO)-->  RAW.TRADES_RAW\n"
        "                                                    |\n"
        "                                          RAW.TRADES_RAW_STREAM\n"
        "                                                    |\n"
        "                                              stg_trades\n"
        "                                                    |\n"
        "                                        int_trades_evaluated\n"
        "                                              /            \\\n"
        "                                     valid_trades      rejected_trades\n"
        "                                          |\n"
        "                                    trade_status (view)",
    )

    add_h2(doc, "5. Connection details for this account")
    add_table(
        doc,
        ["Item", "Value"],
        [
            ["Account URL", "omlvpas-dd77972.snowflakecomputing.com"],
            ["Organization / Account name", "OMLVPAS / DD77972"],
            ["Database", "TRADE_ANALYTICS"],
            ["Warehouse", "TRADE_ANALYTICS_WH"],
            ["Loader role", "TRADE_ANALYTICS_LOADER"],
            ["Transformer role (dbt)", "TRADE_ANALYTICS_TRANSFORMER"],
        ],
        col_widths=[3, 4],
    )
    doc.add_paragraph(
        "Credentials are never stored in this document or in the repository — "
        "they live only in the local, git-ignored .env file. See "
        "docs/SETUP_GUIDE.md for how to populate it."
    )

    doc.save("Trade_Analytics_Summary.docx")
    print("Wrote Trade_Analytics_Summary.docx")


if __name__ == "__main__":
    build()
