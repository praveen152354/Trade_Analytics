# Setup & execution guide

## Prerequisites

- A Snowflake account (trial is fine) with a user that can act as
  `ACCOUNTADMIN` (or `SYSADMIN` + `SECURITYADMIN`) for the initial Terraform
  bootstrap.
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- Python 3.11
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (for the
  Airflow stack)
- Git

## 1. Provision Snowflake with Terraform

```powershell
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in grantee_user = your Snowflake username

$env:SNOWFLAKE_ACCOUNT  = "xy12345.ap-southeast-1"
$env:SNOWFLAKE_USER     = "your_username"
$env:SNOWFLAKE_PASSWORD = "your_password"

terraform init
terraform plan
terraform apply
```

This creates: database `TRADE_ANALYTICS`, warehouse `TRADE_ANALYTICS_WH`,
schemas `RAW`/`STAGING`/`INTERMEDIATE`/`ANALYTICS`, roles
`TRADE_ANALYTICS_LOADER` / `TRADE_ANALYTICS_TRANSFORMER` (granted to your
user), the `RAW.TRADES_STAGE` internal stage, `RAW.TRADE_JSON_FORMAT` file
format, `RAW.TRADES_RAW` landing table, and the `RAW.TRADES_RAW_STREAM`
stream dbt consumes from.

## 2. Configure credentials for the app layer

```powershell
cp .env.example .env
# fill in the same Snowflake values as above, plus SMTP settings if you want
# real failure emails from Airflow.
```

## 3. Generate and load a batch manually (sanity check before automating)

```powershell
cd data_generator
pip install -r requirements.txt
python generate_trades.py --num-trades 200 --seed 42
python load_to_snowflake.py
```

Confirm rows landed: `select count(*) from TRADE_ANALYTICS.RAW.TRADES_RAW;`

## 4. Run dbt

```powershell
cd dbt\trade_analytics
pip install dbt-core==1.8.4 dbt-snowflake==1.8.3
dbt deps
$env:DBT_PROFILES_DIR = (Get-Location).Path
dbt run
dbt test
```

Check results:
```sql
select * from TRADE_ANALYTICS.ANALYTICS.TRADE_STATUS;
select * from TRADE_ANALYTICS.ANALYTICS.REJECTED_TRADES;
```

If you're using **dbt Cloud** instead of dbt-core locally: point a dbt Cloud
project at this repo (`dbt/trade_analytics` as the project subdirectory),
create a Snowflake connection using the `TRADE_ANALYTICS_TRANSFORMER` role,
and dbt Cloud will manage its own connection — `profiles.yml` in this repo
is ignored in that case.

## 5. Run the full pipeline on a schedule with Airflow

```powershell
cp .env orchestration\airflow\.env   # docker compose reads .env from this folder
cd orchestration\airflow
docker compose up --build
```

Open http://localhost:8080 (`AIRFLOW_ADMIN_USER` / `AIRFLOW_ADMIN_PASSWORD`
from `.env`, default `admin`/`admin`), unpause the `trade_pipeline` DAG. It
runs every 30 minutes and can be triggered manually from the UI.

## 6. (Optional) Dashboard

```powershell
cd dashboard
pip install -r requirements.txt
streamlit run streamlit_app.py
```

## 7. CI/CD

GitHub Actions workflows are in `.github/workflows/`:
- `dbt_ci.yml` — `dbt parse` + `dbt build` against an isolated CI schema on
  every PR touching `dbt/**`; `dbt run` + `dbt test` against the main
  target on merge to `main`.
- `terraform_ci.yml` — `fmt`/`init`/`validate`/`plan` on every PR touching
  `terraform/**`; `apply` is manual (`workflow_dispatch`) by design — see
  the comment in that file.

Add these repository secrets for the workflows to run:
`SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER`, `SNOWFLAKE_PASSWORD`,
`SNOWFLAKE_TRANSFORMER_ROLE`, `SNOWFLAKE_DATABASE`, `SNOWFLAKE_WAREHOUSE`,
`SNOWFLAKE_TRANSFORM_SCHEMA`.

## Teardown

```powershell
cd terraform
terraform destroy
```
