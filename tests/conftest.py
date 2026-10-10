import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for folder in ("02_ingestion_python", "09_decisioning_python", "05_airflow/dags"):
    sys.path.insert(0, str(ROOT / folder))
