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
    add_h2(doc, "1. Snowflake objects created (via Terraform + one SQL script)")
    doc.add_paragraph(
        "All objects below were provisioned by terraform apply against the live "
        "trial account (database TRADE_ANALYTICS). One object, "
        "RAW.GENERATE_TRADE_FILES, is deployed by a plain SQL script instead of a "
        "snowflake_procedure_python resource -- the installed provider version has "
        "a read-back bug for that resource type (see the file header in "
        "terraform/sql/generate_trade_files_procedure.sql). Everything else is "
        "fully Terraform-managed."
    )

    add_table(
        doc,
        ["Object", "Type", "Schema", "Purpose"],
        [
            ["TRADE_ANALYTICS_WH", "Warehouse", "—", "XSMALL, auto-suspend 60s. Compute for ingestion and dbt."],
            ["TRADE_ANALYTICS", "Database", "—", "Top-level container for the whole pipeline."],
            ["RAW", "Schema", "TRADE_ANALYTICS", "Landing zone: raw trade files, stage, stream, tasks."],
            ["STAGING", "Schema", "TRADE_ANALYTICS", "dbt staging models (stg_trades)."],
            ["INTERMEDIATE", "Schema", "TRADE_ANALYTICS", "dbt business-rule evaluation (int_trades_evaluated)."],
            ["ANALYTICS", "Schema", "TRADE_ANALYTICS", "dbt marts: valid_trades, rejected_trades, trade_status."],
            ["TRADE_ANALYTICS_LOADER", "Role", "—", "Used by the standalone Python dev/test script (PUT + COPY INTO)."],
            ["TRADE_ANALYTICS_TRANSFORMER", "Role", "—", "Used by dbt (via dbt Cloud) to build every model."],
            ["TRADE_JSON_FORMAT", "File format", "RAW", "JSON, one object per line, used by COPY INTO."],
            ["TRADES_STAGE", "Internal stage", "RAW", "Trade batch files land here (genuine cloud object storage, Snowflake-managed)."],
            ["TRADES_RAW", "Table", "RAW", "Insert-only landing table (raw_payload VARIANT, file_name, loaded_at)."],
            ["TRADES_RAW_STREAM", "Stream", "RAW", "CDC stream on TRADES_RAW; consumed by dbt's stg_trades model."],
            ["GENERATE_TRADE_FILES", "Procedure (Snowpark Python)", "RAW", "Generates a mock trade batch, writes it as .jsonl straight to the stage."],
            ["GENERATE_TRADE_FILES_TASK", "Task", "RAW", "Calls the procedure every 2 min (configurable). Auto-retries 2x on failure."],
            ["INGEST_TRADES_TASK", "Task", "RAW", "COPY INTOs new stage files every 5 min (configurable). Independent schedule from generation."],
            ["TRADE_PIPELINE_ALERT", "Email notification integration", "—", "Lets Snowflake send email for the alert below."],
            ["TASK_FAILURE_ALERT", "Alert", "RAW", "Every 15 min, emails if either task failed in TASK_HISTORY."],
        ],
        col_widths=[1.7, 1.5, 1.0, 3.2],
    )

    doc.add_paragraph(
        "Both roles are granted to the account user PRAVEENMS91 and given USAGE on "
        "the warehouse/database. The transformer role additionally gets "
        "CREATE TABLE / CREATE VIEW on STAGING, INTERMEDIATE and ANALYTICS, and "
        "SELECT on all present-and-future tables/streams in RAW. The loader role "
        "is scoped narrowly to INSERT/SELECT on TRADES_RAW and READ/WRITE on "
        "TRADES_STAGE only. A Task's own ERROR_INTEGRATION property only accepts "
        "cloud-messaging integrations (SNS/Pub-Sub/Event Grid), not EMAIL, which "
        "is why failure alerting goes through a separate ALERT object instead."
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
            ["data_generator/generate_trades.py + load_to_snowflake.py", "Standalone dev/test path (PUT + COPY INTO from a local machine) -- not part of the scheduled production flow."],
            ["terraform/*.tf", "IaC for every Snowflake object listed in section 1, including the Tasks and Alert."],
            ["terraform/sql/generate_trade_files_procedure.sql", "The one object deployed outside Terraform -- see section 1."],
            ["dbt/trade_analytics/models/staging/stg_trades.sql", "Consumes the RAW stream, flattens VARIANT to columns."],
            ["dbt/trade_analytics/models/intermediate/int_trades_evaluated.sql", "All business-rule logic (accept/reject + reason)."],
            ["dbt/trade_analytics/models/marts/valid_trades.sql", "Merge-incremental table of current accepted trades."],
            ["dbt/trade_analytics/models/marts/rejected_trades.sql", "Append-only rejected-trade audit log."],
            ["dbt/trade_analytics/models/marts/trade_status.sql", "View computing ACTIVE/EXPIRED status."],
            ["dbt Cloud (external, not a repo file)", "Hourly job: dbt run then dbt test, reading this repo via a read-only deploy key. Separate Development and Production environments."],
            ["orchestration/airflow/ (alternative)", "Complete Docker Compose Airflow stack, documented but not the primary orchestration path."],
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
        "GENERATE_TRADE_FILES_TASK (every 2 min)\n"
        "      |  CALL RAW.GENERATE_TRADE_FILES(...)\n"
        "      v\n"
        "RAW.TRADES_STAGE  (files)\n"
        "      ^\n"
        "      |  polls\n"
        "INGEST_TRADES_TASK (every 5 min) --(COPY INTO)-->  RAW.TRADES_RAW\n"
        "                                                        |\n"
        "                                              RAW.TRADES_RAW_STREAM\n"
        "                                                        |\n"
        "                                            stg_trades  (dbt Cloud,\n"
        "                                                  |      hourly job)\n"
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
            ["Account URL", "<your-org>-<your-account>.snowflakecomputing.com"],
            ["Organization / Account name", "set in your local .env (SNOWFLAKE_ORGANIZATION_NAME / SNOWFLAKE_ACCOUNT_NAME)"],
            ["Database", "TRADE_ANALYTICS"],
            ["Warehouse", "TRADE_ANALYTICS_WH"],
            ["Loader role", "TRADE_ANALYTICS_LOADER"],
            ["Transformer role (dbt)", "TRADE_ANALYTICS_TRANSFORMER"],
        ],
        col_widths=[3, 4],
    )
    doc.add_paragraph(
        "Account identifiers and credentials are never stored in this document "
        "or in the repository — they live only in the local, git-ignored .env "
        "file. See docs/SETUP_GUIDE.md for how to populate it."
    )

    doc.save("Trade_Analytics_Summary.docx")
    print("Wrote Trade_Analytics_Summary.docx")


if __name__ == "__main__":
    build()
