-- =========================================================
-- queries.sql
-- Exploratory analytics + feature validation queries
-- =========================================================

-- Query 1: Distribution of encounter classes
SELECT
    ENCOUNTERCLASS,
    COUNT(*) AS Total_Encounters,
    ROUND(SUM(TOTAL_CLAIM_COST), 2) AS Aggregate_Cost
FROM encounters
GROUP BY ENCOUNTERCLASS
ORDER BY Total_Encounters DESC;

-- Query 2: High-cost conditions
SELECT
    c.DESCRIPTION AS Condition_Name,
    COUNT(DISTINCT c.PATIENT) AS Patient_Count,
    ROUND(SUM(e.TOTAL_CLAIM_COST), 2) AS Total_Cost
FROM conditions c
JOIN encounters e
    ON c.ENCOUNTER = e.Id
GROUP BY c.DESCRIPTION
HAVING COUNT(DISTINCT c.PATIENT) > 10
ORDER BY Total_Cost DESC
LIMIT 10;

-- Query 3: Demographic stratification
SELECT
    RACE,
    GENDER,
    COUNT(Id) AS Patient_Count,
    ROUND(AVG(HEALTHCARE_EXPENSES), 2) AS Avg_Lifetime_Expenses
FROM patients
GROUP BY RACE, GENDER
ORDER BY RACE, Patient_Count DESC;

-- Query 4: High-utilizer patients
SELECT
    p.Id AS Patient_Id,
    p.GENDER,
    COUNT(e.Id) AS Total_Acute_Visits
FROM patients p
JOIN encounters e
    ON p.Id = e.PATIENT
WHERE e.ENCOUNTERCLASS IN ('inpatient', 'emergency')
GROUP BY p.Id
HAVING COUNT(e.Id) > 3
ORDER BY Total_Acute_Visits DESC;

-- Query 5: Age at encounter
SELECT
    e.Id AS Encounter_Id,
    p.Id AS Patient_Id,
    e.START AS Encounter_Date,
    p.BIRTHDATE,
    CAST((JULIANDAY(e.START) - JULIANDAY(p.BIRTHDATE)) / 365.25 AS INTEGER) AS Age_At_Encounter
FROM encounters e
JOIN patients p
    ON e.PATIENT = p.Id;

-- Query 6: Next admission tracking with LEAD
WITH NextAdmissionTracker AS (
    SELECT
        Id AS Encounter_Id,
        PATIENT,
        START AS Admission_Date,
        STOP AS Discharge_Date,
        ENCOUNTERCLASS,
        LEAD(START) OVER (
            PARTITION BY PATIENT
            ORDER BY START
        ) AS Next_Admission_Date
    FROM encounters
    WHERE ENCOUNTERCLASS IN ('inpatient', 'emergency', 'urgentcare')
)
SELECT
    Encounter_Id,
    PATIENT,
    Admission_Date,
    Discharge_Date,
    Next_Admission_Date,
    CAST((JULIANDAY(Next_Admission_Date) - JULIANDAY(Discharge_Date)) AS INTEGER) AS Days_To_Readmission
FROM NextAdmissionTracker;

-- Query 7: Binary 30-day readmission target
WITH ReadmissionIntervals AS (
    SELECT
        Id AS Encounter_Id,
        PATIENT,
        START AS Admission_Date,
        STOP AS Discharge_Date,
        LEAD(START) OVER (
            PARTITION BY PATIENT
            ORDER BY START
        ) AS Next_Admission_Date
    FROM encounters
    WHERE ENCOUNTERCLASS IN ('inpatient', 'emergency')
)
SELECT
    Encounter_Id,
    PATIENT,
    CAST((JULIANDAY(Next_Admission_Date) - JULIANDAY(Discharge_Date)) AS INTEGER) AS Days_To_Readmission,
    CASE
        WHEN Next_Admission_Date IS NOT NULL
         AND (JULIANDAY(Next_Admission_Date) - JULIANDAY(Discharge_Date)) <= 30 THEN 1
        ELSE 0
    END AS Is_30_Day_Readmit
FROM ReadmissionIntervals;

-- Query 8: Readmission rates by reason code
WITH ReadmissionFlags AS (
    SELECT
        Id AS Encounter_Id,
        CASE
            WHEN LEAD(START) OVER (PARTITION BY PATIENT ORDER BY START) IS NOT NULL
             AND (JULIANDAY(LEAD(START) OVER (PARTITION BY PATIENT ORDER BY START)) - JULIANDAY(STOP)) <= 30
            THEN 1 ELSE 0
        END AS Is_Readmit
    FROM encounters
    WHERE ENCOUNTERCLASS IN ('inpatient', 'emergency')
)
SELECT
    e.REASONCODE,
    COUNT(r.Encounter_Id) AS Total_Discharges,
    SUM(r.Is_Readmit) AS Total_Readmissions,
    ROUND(CAST(SUM(r.Is_Readmit) AS FLOAT) / COUNT(r.Encounter_Id) * 100, 2) AS Readmission_Rate_Pct
FROM ReadmissionFlags r
JOIN encounters e
    ON r.Encounter_Id = e.Id
WHERE e.REASONCODE IS NOT NULL
GROUP BY e.REASONCODE
HAVING COUNT(r.Encounter_Id) > 5
ORDER BY Readmission_Rate_Pct DESC;

-- Query 9: Prior hospitalizations using ROW_NUMBER
SELECT
    Id AS Encounter_Id,
    PATIENT,
    START,
    ROW_NUMBER() OVER (
        PARTITION BY PATIENT
        ORDER BY START
    ) - 1 AS Prior_Inpatient_Visits
FROM encounters
WHERE ENCOUNTERCLASS IN ('inpatient', 'emergency');

-- Query 10: Length of stay
SELECT
    Id AS Encounter_Id,
    CAST((JULIANDAY(STOP) - JULIANDAY(START)) AS REAL) AS Length_Of_Stay_Days
FROM encounters
WHERE ENCOUNTERCLASS = 'inpatient';

-- Query 11: Active comorbidities
SELECT
    e.Id AS Encounter_Id,
    COUNT(c.CODE) AS Active_Conditions_Count
FROM encounters e
LEFT JOIN conditions c
    ON e.PATIENT = c.PATIENT
   AND c.START <= e.START
   AND (c.STOP IS NULL OR c.STOP >= e.START)
GROUP BY e.Id;

-- Query 12: High-risk chronic condition flags
SELECT
    e.Id AS Encounter_Id,
    MAX(CASE WHEN c.DESCRIPTION LIKE '%Diabetes%' THEN 1 ELSE 0 END) AS Has_Diabetes,
    MAX(CASE WHEN c.DESCRIPTION LIKE '%Hypertension%' THEN 1 ELSE 0 END) AS Has_Hypertension,
    MAX(CASE WHEN c.DESCRIPTION LIKE '%Heart Failure%' THEN 1 ELSE 0 END) AS Has_Heart_Failure
FROM encounters e
LEFT JOIN conditions c
    ON e.PATIENT = c.PATIENT
GROUP BY e.Id;

-- Query 13: Average systolic BP
SELECT
    e.Id AS Encounter_Id,
    AVG(CAST(o.VALUE AS REAL)) AS Avg_Systolic_BP
FROM encounters e
JOIN observations o
    ON e.Id = o.ENCOUNTER
WHERE o.DESCRIPTION LIKE '%Systolic Blood Pressure%'
GROUP BY e.Id;

-- Query 14: BMI extraction
SELECT
    e.Id AS Encounter_Id,
    MAX(CAST(o.VALUE AS REAL)) AS Discharge_BMI
FROM encounters e
JOIN observations o
    ON e.Id = o.ENCOUNTER
WHERE o.DESCRIPTION = 'Body Mass Index'
GROUP BY e.Id;

-- Query 15: Polypharmacy indicator
SELECT
    e.Id AS Encounter_Id,
    COUNT(DISTINCT m.CODE) AS Unique_Medications_Prescribed
FROM encounters e
LEFT JOIN medications m
    ON e.Id = m.ENCOUNTER
GROUP BY e.Id;

-- =========================================================
-- Post-prediction analytics queries
-- =========================================================

-- High-risk encounter roster
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

-- Risk bucket segmentation
SELECT
    CASE
        WHEN READMISSION_RISK_SCORE >= 0.80 THEN 'High Risk'
        WHEN READMISSION_RISK_SCORE >= 0.50 THEN 'Medium Risk'
        ELSE 'Low Risk'
    END AS Risk_Bucket,
    COUNT(*) AS Encounter_Count,
    ROUND(AVG(READMISSION_RISK_SCORE), 4) AS Avg_Risk_Score
FROM readmission_predictions
GROUP BY
    CASE
        WHEN READMISSION_RISK_SCORE >= 0.80 THEN 'High Risk'
        WHEN READMISSION_RISK_SCORE >= 0.50 THEN 'Medium Risk'
        ELSE 'Low Risk'
    END;

-- Monthly average risk trend
SELECT
    STRFTIME('%Y-%m', DISCHARGE_DATE) AS Discharge_Month,
    COUNT(*) AS Total_Encounters,
    ROUND(AVG(READMISSION_RISK_SCORE), 4) AS Avg_Risk_Score,
    ROUND(AVG(PREDICTED_READMISSION_CLASS), 4) AS Predicted_Readmit_Rate
FROM readmission_predictions
WHERE DISCHARGE_DATE IS NOT NULL
GROUP BY STRFTIME('%Y-%m', DISCHARGE_DATE)
ORDER BY Discharge_Month;

-- Risk by encounter class
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