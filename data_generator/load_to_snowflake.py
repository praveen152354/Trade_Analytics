"""
Uploads generated trade batch file(s) to the Snowflake internal stage
(@BRONZE.TRADES_STAGE) and issues COPY INTO to load them into BRONZE.TRADES_RAW.

Credentials are read from environment variables (see .env.example). This
script is invoked both from the CLI for manual testing and from the Airflow
DAG (orchestration/airflow/dags/trade_pipeline_dag.py) — a standalone
dev/test path; the scheduled production path is the Snowpark procedure +
Snowflake Tasks in terraform/orchestration.tf.
"""

import argparse
import glob
import os
import sys
from pathlib import Path

import snowflake.connector
from dotenv import load_dotenv

load_dotenv()


def get_connection():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ.get("SNOWFLAKE_PASSWORD"),
        private_key_path=os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH") or None,
        role=os.environ.get("SNOWFLAKE_ROLE", "TRADE_ANALYTICS_LOADER"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "TRADE_ANALYTICS_WH"),
        database=os.environ.get("SNOWFLAKE_DATABASE", "TRADE_ANALYTICS"),
        schema=os.environ.get("SNOWFLAKE_RAW_SCHEMA", "BRONZE"),
    )


def load_files(file_glob: str) -> int:
    files = sorted(glob.glob(file_glob))
    if not files:
        print(f"No files matched pattern: {file_glob}")
        return 0

    conn = get_connection()
    try:
        cur = conn.cursor()
        loaded = 0
        for path in files:
            abs_path = str(Path(path).resolve()).replace("\\", "/")
            print(f"Staging {abs_path} -> @BRONZE.TRADES_STAGE")
            cur.execute(f"PUT 'file://{abs_path}' @BRONZE.TRADES_STAGE OVERWRITE = TRUE")
            loaded += 1

        copy_sql = """
            COPY INTO BRONZE.TRADES_RAW (raw_payload, file_name, loaded_at)
            FROM (
                SELECT $1, METADATA$FILENAME, CURRENT_TIMESTAMP()
                FROM @BRONZE.TRADES_STAGE
            )
            FILE_FORMAT = (FORMAT_NAME = 'BRONZE.TRADE_JSON_FORMAT')
            ON_ERROR = 'SKIP_FILE'
            PURGE = TRUE
        """
        cur.execute(copy_sql)
        result = cur.fetchall()
        print(f"COPY INTO result: {result}")

        # PURGE=TRUE above only removes the STAGED copy -- the local file
        # was never touched, so an unchanged --file-glob (the default,
        # output/*.jsonl) re-matches it on every future invocation
        # forever. That's not just wasted work: PUT's gzip compression
        # embeds a timestamp, so re-uploading identical content later
        # produces a different checksum and slips past Snowflake's own
        # file-level dedup -- confirmed live as the cause of genuine
        # duplicate BRONZE rows (same message_id, different loaded_at)
        # that broke int_trades_evaluated's MERGE downstream. Deleting the
        # local file here, unconditionally once COPY INTO has been
        # attempted, closes that regardless of whether Snowflake's own
        # dedup would have caught the re-upload -- output/ is gitignored
        # scratch, safe to clean up.
        for path in files:
            os.remove(path)
        print(f"Removed {len(files)} local file(s) from {Path(file_glob).parent} after load attempt.")

        return loaded
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Load trade batch file(s) into Snowflake BRONZE.TRADES_RAW")
    parser.add_argument(
        "--file-glob",
        type=str,
        default=str(Path(__file__).parent / "output" / "*.jsonl"),
    )
    args = parser.parse_args()

    loaded = load_files(args.file_glob)
    if loaded == 0:
        sys.exit(1)
    print(f"Staged and loaded {loaded} file(s).")


if __name__ == "__main__":
    main()
