from pathlib import Path
import sqlite3
import json
import joblib
import pandas as pd

from sklearn.model_selection import train_test_split
from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.impute import SimpleImputer
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import roc_auc_score, recall_score, precision_recall_curve, auc
from xgboost import XGBClassifier

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DB_PATH = PROJECT_ROOT / "database" / "healthcare.db"
MODELS_PATH = PROJECT_ROOT / "models"

def main():
    MODELS_PATH.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(DB_PATH)
    df = pd.read_sql_query("SELECT * FROM ml_feature_matrix;", conn)
    conn.close()

    # Remove identifiers and leakage columns
    df = df.drop(columns=["Encounter_Id", "Patient_Id", "Days_To_Readmission"], errors="ignore")

    X = df.drop(columns=["Target_Readmitted_30D"])
    y = df["Target_Readmitted_30D"]

    categorical_cols = X.select_dtypes(include=["object"]).columns.tolist()
    numerical_cols = X.select_dtypes(exclude=["object"]).columns.tolist()

    X_train, X_test, y_train, y_test = train_test_split(
        X, y,
        test_size=0.2,
        random_state=42,
        stratify=y
    )

    numeric_transformer = Pipeline([
        ("imputer", SimpleImputer(strategy="median")),
        ("scaler", StandardScaler())
    ])

    categorical_transformer = Pipeline([
        ("imputer", SimpleImputer(strategy="most_frequent")),
        ("onehot", OneHotEncoder(handle_unknown="ignore"))
    ])

    preprocessor = ColumnTransformer(
        transformers=[
            ("num", numeric_transformer, numerical_cols),
            ("cat", categorical_transformer, categorical_cols)
        ]
    )

    log_model = Pipeline([
        ("preprocessing", preprocessor),
        ("model", LogisticRegression(max_iter=1000, class_weight="balanced"))
    ])

    log_model.fit(X_train, y_train)

    y_pred = log_model.predict(X_test)
    y_proba = log_model.predict_proba(X_test)[:, 1]

    roc = roc_auc_score(y_test, y_proba)
    recall = recall_score(y_test, y_pred)
    precision, recall_curve, _ = precision_recall_curve(y_test, y_proba)
    pr_auc = auc(recall_curve, precision)

    scale_pos_weight = (y_train == 0).sum() / (y_train == 1).sum()

    xgb_model = Pipeline([
        ("preprocessing", preprocessor),
        ("model", XGBClassifier(
            n_estimators=100,
            max_depth=5,
            learning_rate=0.1,
            scale_pos_weight=scale_pos_weight,
            random_state=42,
            eval_metric="logloss"
        ))
    ])

    xgb_model.fit(X_train, y_train)

    y_pred_xgb = xgb_model.predict(X_test)
    y_proba_xgb = xgb_model.predict_proba(X_test)[:, 1]

    roc_xgb = roc_auc_score(y_test, y_proba_xgb)
    recall_xgb = recall_score(y_test, y_pred_xgb)
    precision_xgb, recall_curve_xgb, _ = precision_recall_curve(y_test, y_proba_xgb)
    pr_auc_xgb = auc(recall_curve_xgb, precision_xgb)

    metrics_summary = {
        "logistic_regression": {
            "roc_auc": float(roc),
            "recall": float(recall),
            "pr_auc": float(pr_auc)
        },
        "xgboost": {
            "roc_auc": float(roc_xgb),
            "recall": float(recall_xgb),
            "pr_auc": float(pr_auc_xgb)
        }
    }

    joblib.dump(log_model, MODELS_PATH / "logistic_regression.pkl")
    joblib.dump(xgb_model, MODELS_PATH / "xgboost_model.pkl")

    with open(MODELS_PATH / "metrics.json", "w") as f:
        json.dump(metrics_summary, f, indent=4)

    print("Training complete.")
    print(metrics_summary)

if __name__ == "__main__":
    main()