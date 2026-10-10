FROM astrocrpublic.azurecr.io/runtime:3.0-2

# dbt + the ingestion package live under /usr/local/airflow/include (copied by astro dev start)
ENV DBT_PROJECT_DIR=/usr/local/airflow/include/dbt \
    DBT_PROFILES_DIR=/usr/local/airflow/include/dbt \
    INGEST_DIR=/usr/local/airflow/include/ingestion \
    PG_HOST=host.docker.internal
