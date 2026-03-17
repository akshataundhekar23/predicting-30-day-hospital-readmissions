from pathlib import Path
import sqlite3
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = PROJECT_ROOT / "database" / "healthcare.db"
VIEWS_PATH = PROJECT_ROOT / "database" / "views.sql"

def main():
    conn = sqlite3.connect(DB_PATH)

    with open(VIEWS_PATH, "r", encoding="utf-8") as f:
        conn.executescript(f.read())

    # Basic validation
    views_df = pd.read_sql_query("""
    SELECT name
    FROM sqlite_master
    WHERE type = 'view'
    ORDER BY name;
    """, conn)
    print("Created views:")
    print(views_df)

    feature_df = pd.read_sql_query("""
    SELECT *
    FROM ml_feature_matrix
    LIMIT 10;
    """, conn)
    print("\nFeature matrix preview:")
    print(feature_df.head())

    target_dist = pd.read_sql_query("""
    SELECT Target_Readmitted_30D, COUNT(*) AS row_count
    FROM ml_feature_matrix
    GROUP BY Target_Readmitted_30D
    ORDER BY Target_Readmitted_30D;
    """, conn)
    print("\nTarget distribution:")
    print(target_dist)

    conn.close()
    print("\nFeature engineering complete.")

if __name__ == "__main__":
    main()