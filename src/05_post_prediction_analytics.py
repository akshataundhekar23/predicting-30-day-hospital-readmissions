from pathlib import Path
import sqlite3
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = PROJECT_ROOT / "database" / "healthcare.db"
OUTPUT_DIR = PROJECT_ROOT / "outputs" / "sql_results"

def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)

    high_risk_df = pd.read_sql_query("""
    SELECT
        rp.ENCOUNTER_ID,
        rp.PATIENT_ID,
        rp.DISCHARGE_DATE,
        rp.PREDICTED_READMISSION_CLASS,
        ROUND(rp.READMISSION_RISK_SCORE, 4) AS READMISSION_RISK_SCORE,
        rp.MODEL_VERSION,
        e.ENCOUNTERCLASS,
        e.REASONCODE,
        p.GENDER,
        p.RACE,
        p.COUNTY
    FROM readmission_predictions rp
    LEFT JOIN encounters e
        ON rp.ENCOUNTER_ID = e.Id
    LEFT JOIN patients p
        ON rp.PATIENT_ID = p.Id
    WHERE rp.READMISSION_RISK_SCORE >= 0.80
    ORDER BY rp.READMISSION_RISK_SCORE DESC, rp.DISCHARGE_DATE DESC;
    """, conn)

    monthly_risk_df = pd.read_sql_query("""
    SELECT
        STRFTIME('%Y-%m', DISCHARGE_DATE) AS Discharge_Month,
        COUNT(*) AS Total_Encounters,
        ROUND(AVG(READMISSION_RISK_SCORE), 4) AS Avg_Risk_Score,
        ROUND(AVG(PREDICTED_READMISSION_CLASS), 4) AS Predicted_Readmit_Rate
    FROM readmission_predictions
    WHERE DISCHARGE_DATE IS NOT NULL
    GROUP BY STRFTIME('%Y-%m', DISCHARGE_DATE)
    ORDER BY Discharge_Month;
    """, conn)

    encounter_class_risk_df = pd.read_sql_query("""
    SELECT
        e.ENCOUNTERCLASS,
        COUNT(*) AS Total_Encounters,
        ROUND(AVG(rp.READMISSION_RISK_SCORE), 4) AS Avg_Risk_Score,
        SUM(rp.PREDICTED_READMISSION_CLASS) AS Predicted_Readmissions,
        ROUND(AVG(rp.PREDICTED_READMISSION_CLASS), 4) AS Predicted_Readmit_Rate
    FROM readmission_predictions rp
    JOIN encounters e
        ON rp.ENCOUNTER_ID = e.Id
    GROUP BY e.ENCOUNTERCLASS
    ORDER BY Avg_Risk_Score DESC;
    """, conn)

    high_risk_df.to_csv(OUTPUT_DIR / "high_risk_patients.csv", index=False)
    monthly_risk_df.to_csv(OUTPUT_DIR / "monthly_risk_summary.csv", index=False)
    encounter_class_risk_df.to_csv(OUTPUT_DIR / "encounter_class_risk_summary.csv", index=False)

    conn.close()
    print("Post-prediction analytics complete.")

if __name__ == "__main__":
    main()