# Setup & execution guide

## Prerequisites

- A Snowflake account (trial is fine) with a user that can act as
  `ACCOUNTADMIN` (or `SYSADMIN` + `SECURITYADMIN`) for the initial Terraform
  bootstrap.
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- Python 3.11 (see the note in step 4 — dbt-core doesn't yet run on very new
  Python releases)
- A dbt Cloud account (trial is fine) if you want the scheduled dbt
  run/test job — otherwise `dbt run`/`dbt test` from the CLI is enough
- Git
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — only
  if you want the Airflow *alternative* orchestrator; not needed for the
  primary Snowflake-native + dbt Cloud path

## 1. Deploy `RAW.GENERATE_TRADE_FILES`, then provision everything else with Terraform

This one object is deployed via plain SQL rather than Terraform — see the
comment at the top of `terraform/sql/generate_trade_files_procedure.sql`
for why (a provider read-back bug for Python procedure objects).

```powershell
cd terraform
cp terraform.tfvars.example terraform.tfvars
# fill in grantee_user = your Snowflake username, alert_email = an email
# address that's actually verified on your Snowflake user (see step 2)

$env:SNOWFLAKE_ORGANIZATION_NAME = "your_org"      # from your Snowsight URL
$env:SNOWFLAKE_ACCOUNT_NAME      = "your_account"  # ditto
$env:SNOWFLAKE_USER              = "your_username"
$env:SNOWFLAKE_PASSWORD          = "your_password"

terraform init
terraform plan
terraform apply
```

Bootstrap the procedure first (needs the warehouse/database from `apply`
above to already exist, so run this after the first `terraform apply`, or
before if the warehouse/database already exist from a prior run):

```powershell
pip install -q snowflake-connector-python python-dotenv
python -c "
import os
import snowflake.connector
from dotenv import load_dotenv
load_dotenv(dotenv_path='../.env')
conn = snowflake.connector.connect(
    account=os.environ['SNOWFLAKE_ACCOUNT'],
    user=os.environ['SNOWFLAKE_USER'],
    password=os.environ['SNOWFLAKE_PASSWORD'],
    role='ACCOUNTADMIN', warehouse='TRADE_ANALYTICS_WH', database='TRADE_ANALYTICS', schema='RAW',
)
conn.cursor().execute(open('sql/generate_trade_files_procedure.sql', encoding='utf-8').read())
print('deployed')
"
```

`terraform apply` creates: database `TRADE_ANALYTICS`, warehouse
`TRADE_ANALYTICS_WH`, schemas `RAW`/`STAGING`/`INTERMEDIATE`/`ANALYTICS`,
roles `TRADE_ANALYTICS_LOADER` / `TRADE_ANALYTICS_TRANSFORMER`, the
`RAW.TRADES_STAGE` internal stage, `RAW.TRADE_JSON_FORMAT` file format,
`RAW.TRADES_RAW` landing table, the `RAW.TRADES_RAW_STREAM` stream dbt
consumes from, **and the orchestration layer**: `GENERATE_TRADE_FILES_TASK`
(writes a new batch to the stage every 2 min, configurable via
`trade_generation_schedule_minutes`), `INGEST_TRADES_TASK` (COPY INTOs new
files every 5 min, configurable via `ingestion_schedule_minutes`), and (if
`alert_email` is set) an email notification integration plus a
`TASK_FAILURE_ALERT` that checks `TASK_HISTORY` every 15 minutes.

## 2. Configure credentials for local scripts / CI

```powershell
cp .env.example .env
# fill in SNOWFLAKE_ACCOUNT, SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME,
# SNOWFLAKE_USER, SNOWFLAKE_PASSWORD as above.
```

The email notification integration only allows recipients that are
verified against a user in your Snowflake account — check yours with
`DESCRIBE USER <your_username>` and look at the `EMAIL` property; use that
exact address for `alert_email`, not necessarily the one you signed up
with.

## 3. (Optional) Sanity-check ingestion manually before relying on the schedule

```powershell
python -c "
import os, snowflake.connector
from dotenv import load_dotenv
load_dotenv()
conn = snowflake.connector.connect(account=os.environ['SNOWFLAKE_ACCOUNT'], user=os.environ['SNOWFLAKE_USER'], password=os.environ['SNOWFLAKE_PASSWORD'], role='ACCOUNTADMIN', warehouse='TRADE_ANALYTICS_WH', database='TRADE_ANALYTICS', schema='RAW')
conn.cursor().execute('CALL RAW.GENERATE_TRADE_FILES(50)')
"
```
Then check `select count(*) from TRADE_ANALYTICS.RAW.TRADES_RAW;` after
`INGEST_TRADES_TASK`'s next scheduled run (or run its `COPY INTO` manually —
see `terraform/orchestration.tf` for the exact statement).

`data_generator/generate_trades.py` + `load_to_snowflake.py` are kept as a
standalone alternative for local development/testing (PUT + COPY INTO from
your machine instead of the in-Snowflake Snowpark path) — not part of the
scheduled production flow.

## 4. Run dbt

dbt-core 1.8's dependencies (protobuf's compiled wheel) don't yet support
very new Python releases (this broke on Python 3.14 with `TypeError:
Metaclasses with custom tp_new are not supported`). If `python --version`
is newer than 3.12, install Python 3.11 alongside it and give dbt its own
virtualenv rather than fighting the system interpreter:

```powershell
cd dbt\trade_analytics
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install dbt-core==1.8.4 dbt-snowflake==1.8.3
.\.venv\Scripts\dbt.exe deps
$env:DBT_PROFILES_DIR = (Get-Location).Path
.\.venv\Scripts\dbt.exe run
.\.venv\Scripts\dbt.exe test
```

(If your system Python is already 3.9–3.12, a plain `pip install dbt-core
dbt-snowflake` and bare `dbt` command work fine — skip the venv dance.)

Check results:
```sql
select * from TRADE_ANALYTICS.ANALYTICS.TRADE_STATUS;
select * from TRADE_ANALYTICS.ANALYTICS.REJECTED_TRADES;
```

## 5. Schedule dbt run/test with dbt Cloud

1. Create a dbt Cloud project pointing at this repo, subdirectory
   `dbt/trade_analytics`.
2. Repository access: dbt Cloud generates an SSH deploy key when you add
   the repo with `git_clone_strategy: deploy_key` — add that public key to
   the GitHub repo's Settings → Deploy keys (read-only) so dbt Cloud can
   clone it.
3. Connection: Snowflake, account = your org-account identifier, database
   `TRADE_ANALYTICS`, warehouse `TRADE_ANALYTICS_WH`, role
   `TRADE_ANALYTICS_TRANSFORMER`.
4. Create a **Development** environment (credentials: your Snowflake user,
   schema `ANALYTICS`) and a **Production** environment (same connection,
   its own credentials) — dbt Cloud requires a development environment to
   be configured even if you only use the IDE occasionally.
5. Create a Job on the Production environment: steps `dbt run` then
   `dbt test`, a cron schedule (hourly is a reasonable default for this
   volume), and turn on failure notifications (Deploy → Notifications) for
   email/Slack alerts independent of the Snowflake-side `TASK_FAILURE_ALERT`.

All of the above is scriptable via the [dbt Cloud Admin API](https://docs.getdbt.com/dbt-cloud/api-v2)
if you'd rather automate it than click through the UI — that's how this
project's own dbt Cloud project was set up.

## 6. (Optional) Alternative orchestrator: Airflow

Only needed if you'd rather run generate → load → `dbt run` → `dbt test`
as one Airflow DAG instead of the Snowflake Tasks + dbt Cloud path above:

```powershell
cp .env orchestration\airflow\.env   # docker compose reads .env from this folder
cd orchestration\airflow
docker compose up --build
```

Open http://localhost:8080 (`AIRFLOW_ADMIN_USER` / `AIRFLOW_ADMIN_PASSWORD`
from `.env`, default `admin`/`admin`), unpause the `trade_pipeline` DAG. It
runs every 30 minutes and can be triggered manually from the UI.

## 7. (Optional) Dashboard

```powershell
cd dashboard
pip install -r requirements.txt
streamlit run streamlit_app.py
```

## 8. CI/CD

GitHub Actions workflows are in `.github/workflows/`:
- `dbt_ci.yml` — `dbt parse` + `dbt build` against an isolated CI schema on
  every PR touching `dbt/**`; `dbt run` + `dbt test` against the main
  target on merge to `main`.
- `terraform_ci.yml` — `fmt`/`init`/`validate`/`plan` on every PR touching
  `terraform/**`; `apply` is manual (`workflow_dispatch`) by design — see
  the comment in that file. The manual `apply` job also deploys
  `RAW.GENERATE_TRADE_FILES` from the SQL script before running Terraform.

Add these repository secrets for the workflows to run:
`SNOWFLAKE_ORGANIZATION_NAME`, `SNOWFLAKE_ACCOUNT_NAME`, `SNOWFLAKE_USER`,
`SNOWFLAKE_PASSWORD`, `SNOWFLAKE_TRANSFORMER_ROLE`, `SNOWFLAKE_DATABASE`,
`SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_TRANSFORM_SCHEMA`, `ALERT_EMAIL`.

## Teardown

```powershell
cd terraform
terraform destroy
```
