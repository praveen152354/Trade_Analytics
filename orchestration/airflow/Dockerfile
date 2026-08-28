FROM apache/airflow:2.9.3-python3.11

USER airflow

COPY data_generator/requirements.txt /tmp/generator-requirements.txt
RUN pip install --no-cache-dir -r /tmp/generator-requirements.txt

RUN pip install --no-cache-dir \
    apache-airflow-providers-snowflake==5.6.0 \
    dbt-core==1.8.4 \
    dbt-snowflake==1.8.3
