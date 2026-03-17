from pathlib import Path
import sqlite3
import numpy as np
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = PROJECT_ROOT / "data" / "raw"
DB_PATH = PROJECT_ROOT / "database" / "healthcare.db"
SCHEMA_PATH = PROJECT_ROOT / "database" / "schema.sql"

TABLE_CONFIG = {
    "patients": {
        "file": RAW_DIR / "patients.csv",
        "usecols": [
            "Id", "BIRTHDATE", "DEATHDATE", "GENDER", "RACE", "ETHNICITY",
            "COUNTY", "HEALTHCARE_EXPENSES", "HEALTHCARE_COVERAGE"
        ],
        "rename": {}
    },
    "encounters": {
        "file": RAW_DIR / "encounters.csv",
        "usecols": [
            "Id", "START", "STOP", "PATIENT", "ORGANIZATION", "PROVIDER", "PAYER",
            "ENCOUNTERCLASS", "CODE", "DESCRIPTION", "BASE_ENCOUNTER_COST",
            "TOTAL_CLAIM_COST", "PAYER_COVERAGE", "REASONCODE"
        ],
        "rename": {}
    },
    "conditions": {
        "file": RAW_DIR / "conditions.csv",
        "usecols": [
            "START", "STOP", "PATIENT", "ENCOUNTER", "CODE", "DESCRIPTION"
        ],
        "rename": {}
    },
    "observations": {
        "file": RAW_DIR / "observations.csv",
        "usecols": [
            "DATE", "PATIENT", "ENCOUNTER", "CODE", "DESCRIPTION", "VALUE", "UNITS", "TYPE"
        ],
        "rename": {}
    },
    "medications": {
        "file": RAW_DIR / "medications.csv",
        "usecols": [
            "START", "STOP", "PATIENT", "PAYER", "ENCOUNTER", "CODE", "DESCRIPTION",
            "BASE_COST", "PAYER_COVERAGE", "DISPENSES", "TOTALCOST", "REASONCODE"
        ],
        "rename": {}
    }
}

def standardize_missing_values(df: pd.DataFrame) -> pd.DataFrame:
    return df.replace({np.nan: None})

def load_csv_subset(csv_path: Path, selected_columns: list, rename_map: dict = None) -> pd.DataFrame:
    df = pd.read_csv(csv_path, usecols=selected_columns)
    if rename_map:
        df = df.rename(columns=rename_map)
    return standardize_missing_values(df)

def main():
    if DB_PATH.exists():
        DB_PATH.unlink()

    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA foreign_keys = ON;")

    with open(SCHEMA_PATH, "r", encoding="utf-8") as f:
        conn.executescript(f.read())

    load_order = ["patients", "encounters", "conditions", "observations", "medications"]

    for table_name in load_order:
        config = TABLE_CONFIG[table_name]
        df = load_csv_subset(
            csv_path=config["file"],
            selected_columns=config["usecols"],
            rename_map=config["rename"]
        )
        print(f"Loading {table_name}: {df.shape}")
        df.to_sql(table_name, conn, if_exists="append", index=False)

    for table in load_order + ["readmission_predictions"]:
        count = pd.read_sql_query(f"SELECT COUNT(*) AS row_count FROM {table};", conn)
        print(f"{table}: {count.loc[0, 'row_count']}")

    conn.close()
    print("Ingestion complete.")

if __name__ == "__main__":
    main()