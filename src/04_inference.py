from pathlib import Path
import sqlite3
import joblib
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = PROJECT_ROOT / "database" / "healthcare.db"
MODEL_PATH = PROJECT_ROOT / "models" / "xgboost_model.pkl"

def main():
    conn = sqlite3.connect(DB_PATH)

    df_full = pd.read_sql_query("SELECT * FROM ml_feature_matrix;", conn)

    ids_df = df_full[["Encounter_Id", "Patient_Id"]].copy()

    X_full = df_full.drop(columns=[
        "Target_Readmitted_30D",
        "Encounter_Id",
        "Patient_Id",
        "Days_To_Readmission"
    ], errors="ignore")

    model = joblib.load(MODEL_PATH)

    pred_class = model.predict(X_full)
    pred_prob = model.predict_proba(X_full)[:, 1]

    predictions_df = ids_df.copy()
    predictions_df["PREDICTED_READMISSION_CLASS"] = pred_class
    predictions_df["READMISSION_RISK_SCORE"] = pred_prob

    discharge_df = pd.read_sql_query("""
    SELECT Id AS Encounter_Id, STOP AS DISCHARGE_DATE
    FROM encounters;
    """, conn)

    predictions_df = predictions_df.merge(discharge_df, on="Encounter_Id", how="left")
    predictions_df["MODEL_VERSION"] = "xgboost_v1"

    predictions_df = predictions_df.rename(columns={
        "Encounter_Id": "ENCOUNTER_ID",
        "Patient_Id": "PATIENT_ID"
    })

    conn.execute("DELETE FROM readmission_predictions;")
    conn.commit()

    predictions_df.to_sql("readmission_predictions", conn, if_exists="append", index=False)

    check = pd.read_sql_query("SELECT COUNT(*) AS total_predictions FROM readmission_predictions;", conn)
    print(check)

    conn.close()
    print("Inference complete and predictions stored.")

if __name__ == "__main__":
    main()