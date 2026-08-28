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

## 1. Bootstrap remote state, deploy `BRONZE.GENERATE_TRADE_FILES`, then provision everything else with Terraform

**State backend (once per AWS account):** this project uses an S3 backend
(`terraform/backend.tf`) so local applies and CI share the same state — a
plain local state file would leave CI's `terraform apply` job trying to
recreate everything from scratch on every run. The bucket/lock file can't
be created by Terraform itself (nothing to point the backend at yet), so
run this once first:

```powershell
cd terraform
pip install -q boto3 python-dotenv
python bootstrap_state_backend.py
```

If you're standing this up fresh (not reusing this project's exact bucket
names), edit the bucket name in both `terraform/backend.tf` and
`terraform/bootstrap_state_backend.py` to something globally unique first
— they have to match each other exactly.

`BRONZE.GENERATE_TRADE_FILES` is deployed via plain SQL
(`terraform/sql/generate_trade_files_procedure.sql`) rather than a
Terraform resource, so its Python body stays under direct version control
in one reviewable file. Run it once, before the first `terraform apply` —
see that file's header comment for the exact command.

```powershell
cp terraform.tfvars.example terraform.tfvars
# fill in grantee_user = your Snowflake username, alert_email = an email
# address that's actually verified on your Snowflake user (see step 2)

$env:SNOWFLAKE_ORGANIZATION_NAME = "your_org"      # from your Snowsight URL
$env:SNOWFLAKE_ACCOUNT_NAME      = "your_account"  # ditto
$env:SNOWFLAKE_USER              = "your_username"
$env:SNOWFLAKE_PASSWORD          = "your_password"
$env:AWS_ACCESS_KEY_ID           = "your_aws_key"    # for the S3 FX-rates integration (terraform/aws.tf, s3_integration.tf)
$env:AWS_SECRET_ACCESS_KEY       = "your_aws_secret"

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
    role='ACCOUNTADMIN', warehouse='TRADE_ANALYTICS_WH', database='TRADE_ANALYTICS', schema='BRONZE',
)
conn.cursor().execute(open('sql/generate_trade_files_procedure.sql', encoding='utf-8').read())
print('deployed')
"
```

`terraform apply` creates: database `TRADE_ANALYTICS`, warehouse
`TRADE_ANALYTICS_WH`, medallion schemas `BRONZE`/`SILVER`/`GOLD`,
roles `TRADE_ANALYTICS_LOADER` / `TRADE_ANALYTICS_TRANSFORMER`, the
`BRONZE.TRADES_STAGE` internal stage, `BRONZE.TRADE_JSON_FORMAT` file format,
`BRONZE.TRADES_RAW` landing table, the `BRONZE.TRADES_RAW_STREAM` stream dbt
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
conn = snowflake.connector.connect(account=os.environ['SNOWFLAKE_ACCOUNT'], user=os.environ['SNOWFLAKE_USER'], password=os.environ['SNOWFLAKE_PASSWORD'], role='ACCOUNTADMIN', warehouse='TRADE_ANALYTICS_WH', database='TRADE_ANALYTICS', schema='BRONZE')
conn.cursor().execute('CALL BRONZE.GENERATE_TRADE_FILES(50)')
"
```
Then check `select count(*) from TRADE_ANALYTICS.BRONZE.TRADES_RAW;` after
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
select * from TRADE_ANALYTICS.GOLD.TRADE_STATUS;
select * from TRADE_ANALYTICS.GOLD.REJECTED_TRADES;
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
   schema `GOLD`) and a **Production** environment (same connection,
   its own credentials) — dbt Cloud requires a development environment to
   be configured even if you only use the IDE occasionally.
5. Create a Job on the Production environment: steps `dbt run` then
   `dbt test`, a cron schedule (hourly is a reasonable default for this
   volume), and turn on failure notifications (Deploy → Notifications) for
   email/Slack alerts independent of the Snowflake-side `TASK_FAILURE_ALERT`.
6. Create a second Job, steps `dbt snapshot` only, scheduled monthly
   (cron `0 1 1 * *` — 01:00 UTC on the 1st) to populate
   `valid_trades_snapshot`, the Type 2 SCD history of the trade book. In the
   dbt Cloud UI this is the "Custom Cron Schedule" option under the job's
   Schedule tab, not the day-of-month picker (which can't express "run
   once, on the 1st, ignoring the other trigger types").

All of the above is scriptable via the [dbt Cloud Admin API](https://docs.getdbt.com/dbt-cloud/api-v2)
if you'd rather automate it than click through the UI — that's how this
project's own dbt Cloud project was set up.

## 6. Dashboard

Runs natively in Snowflake (Streamlit in Snowflake) once `terraform apply`
has provisioned `terraform/streamlit.tf` — view it in Snowsight under
**Projects → Streamlit**. For local development instead:

```powershell
cd dashboard
pip install -r requirements.txt
streamlit run Summary.py
```

## 7. CI/CD

GitHub Actions workflows are in `.github/workflows/`:
- `dbt_ci.yml` — `dbt parse` + `dbt build` against an isolated CI schema on
  every PR touching `dbt/**`; `dbt run` + `dbt test` against the main
  target on merge to `main`.
- `terraform_ci.yml` — `fmt`/`init`/`validate`/`plan` on every PR touching
  `terraform/**`; `apply` is manual (`workflow_dispatch`) by design — see
  the comment in that file. The manual `apply` job also deploys
  `BRONZE.GENERATE_TRADE_FILES` from the SQL script before running Terraform.

Add these repository secrets for the workflows to run:
`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_ORGANIZATION_NAME`, `SNOWFLAKE_ACCOUNT_NAME`,
`SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`, `SNOWFLAKE_TRANSFORMER_ROLE`,
`SNOWFLAKE_DATABASE`, `SNOWFLAKE_WAREHOUSE`, `SNOWFLAKE_TRANSFORM_SCHEMA`,
`ALERT_EMAIL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (the last two
are also needed for `terraform plan`/`apply` to authenticate to the S3
FX-rates bucket/role — see `terraform/aws.tf`). CI's `terraform` jobs read
state from the shared S3 backend set up in step 1 above, so `plan`/`apply`
in CI see the same reality as local runs.

## Teardown

```powershell
cd terraform
terraform destroy
```
