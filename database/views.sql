-- =========================================================
-- views.sql
-- Feature engineering views for ML
-- =========================================================

DROP VIEW IF EXISTS readmission_base;
DROP VIEW IF EXISTS active_conditions_per_encounter;
DROP VIEW IF EXISTS vitals_per_encounter;
DROP VIEW IF EXISTS medications_per_encounter;
DROP VIEW IF EXISTS ml_feature_matrix;

-- ---------------------------------------------------------
-- View 1: readmission_base
-- Core temporal logic using LEAD, ROW_NUMBER, JULIANDAY
-- ---------------------------------------------------------
CREATE VIEW readmission_base AS
WITH ordered_encounters AS (
    SELECT
        e.Id AS Encounter_Id,
        e.PATIENT,
        e.START,
        e.STOP,
        e.ENCOUNTERCLASS,
        e.REASONCODE,
        e.TOTAL_CLAIM_COST,
        LEAD(e.START) OVER (
            PARTITION BY e.PATIENT
            ORDER BY e.START
        ) AS Next_Admission_Date,
        ROW_NUMBER() OVER (
            PARTITION BY e.PATIENT
            ORDER BY e.START
        ) - 1 AS Prior_Visits
    FROM encounters e
    WHERE e.ENCOUNTERCLASS IN ('inpatient', 'emergency')
)
SELECT
    Encounter_Id,
    PATIENT,
    START,
    STOP,
    ENCOUNTERCLASS,
    REASONCODE,
    TOTAL_CLAIM_COST,
    Prior_Visits,
    Next_Admission_Date,
    CAST((JULIANDAY(STOP) - JULIANDAY(START)) AS REAL) AS Length_Of_Stay,
    CAST((JULIANDAY(Next_Admission_Date) - JULIANDAY(STOP)) AS INTEGER) AS Days_To_Readmission,
    CASE
        WHEN STOP IS NOT NULL
         AND Next_Admission_Date IS NOT NULL
         AND (JULIANDAY(Next_Admission_Date) - JULIANDAY(STOP)) <= 30
        THEN 1
        ELSE 0
    END AS Target_Readmitted_30D
FROM ordered_encounters
WHERE STOP IS NOT NULL;

-- ---------------------------------------------------------
-- View 2: active_conditions_per_encounter
-- Condition burden and disease flags
-- Uses LEFT JOIN + temporal filtering
-- ---------------------------------------------------------
CREATE VIEW active_conditions_per_encounter AS
SELECT
    e.Id AS Encounter_Id,
    COUNT(c.CODE) AS Active_Conditions_Count,
    MAX(CASE WHEN c.DESCRIPTION LIKE '%Diabetes%' THEN 1 ELSE 0 END) AS Has_Diabetes,
    MAX(CASE WHEN c.DESCRIPTION LIKE '%Hypertension%' THEN 1 ELSE 0 END) AS Has_Hypertension,
    MAX(CASE WHEN c.DESCRIPTION LIKE '%Heart Failure%' THEN 1 ELSE 0 END) AS Has_Heart_Failure
FROM encounters e
LEFT JOIN conditions c
    ON e.PATIENT = c.PATIENT
   AND c.START <= e.START
   AND (c.STOP IS NULL OR c.STOP >= e.START)
WHERE e.ENCOUNTERCLASS IN ('inpatient', 'emergency')
GROUP BY e.Id;

-- ---------------------------------------------------------
-- View 3: vitals_per_encounter
-- Pulls BP + BMI from observations
-- ---------------------------------------------------------
CREATE VIEW vitals_per_encounter AS
SELECT
    e.Id AS Encounter_Id,
    AVG(
        CASE
            WHEN o.DESCRIPTION LIKE '%Systolic Blood Pressure%'
            THEN CAST(o.VALUE AS REAL)
            ELSE NULL
        END
    ) AS Avg_Systolic_BP,
    MAX(
        CASE
            WHEN o.DESCRIPTION = 'Body Mass Index'
            THEN CAST(o.VALUE AS REAL)
            ELSE NULL
        END
    ) AS Discharge_BMI
FROM encounters e
LEFT JOIN observations o
    ON e.Id = o.ENCOUNTER
WHERE e.ENCOUNTERCLASS IN ('inpatient', 'emergency')
GROUP BY e.Id;

-- ---------------------------------------------------------
-- View 4: medications_per_encounter
-- Polypharmacy proxy
-- ---------------------------------------------------------
CREATE VIEW medications_per_encounter AS
SELECT
    e.Id AS Encounter_Id,
    COUNT(DISTINCT m.CODE) AS Unique_Medications_Prescribed
FROM encounters e
LEFT JOIN medications m
    ON e.Id = m.ENCOUNTER
WHERE e.ENCOUNTERCLASS IN ('inpatient', 'emergency')
GROUP BY e.Id;

-- ---------------------------------------------------------
-- View 5: ml_feature_matrix
-- Final flattened ML-ready dataset
-- ---------------------------------------------------------
CREATE VIEW ml_feature_matrix AS
SELECT
    rb.Encounter_Id,
    rb.PATIENT AS Patient_Id,

    -- Demographics
    p.GENDER,
    p.RACE,
    p.ETHNICITY,
    p.COUNTY,

    -- Dynamic age at encounter
    CAST((JULIANDAY(rb.START) - JULIANDAY(p.BIRTHDATE)) / 365.25 AS INTEGER) AS Age,

    -- Utilization and temporal features
    rb.ENCOUNTERCLASS,
    rb.REASONCODE,
    rb.Length_Of_Stay,
    rb.Prior_Visits,
    rb.Days_To_Readmission,
    rb.TOTAL_CLAIM_COST,

    -- Condition burden
    COALESCE(ac.Active_Conditions_Count, 0) AS Active_Conditions,
    COALESCE(ac.Has_Diabetes, 0) AS Has_Diabetes,
    COALESCE(ac.Has_Hypertension, 0) AS Has_Hypertension,
    COALESCE(ac.Has_Heart_Failure, 0) AS Has_Heart_Failure,

    -- Vitals
    vp.Avg_Systolic_BP,
    vp.Discharge_BMI,

    -- Medication complexity
    COALESCE(mp.Unique_Medications_Prescribed, 0) AS Unique_Medications_Prescribed,

    -- Static socioeconomic proxies
    p.HEALTHCARE_EXPENSES,
    p.HEALTHCARE_COVERAGE,

    -- Target
    rb.Target_Readmitted_30D

FROM readmission_base rb
JOIN patients p
    ON rb.PATIENT = p.Id
LEFT JOIN active_conditions_per_encounter ac
    ON rb.Encounter_Id = ac.Encounter_Id
LEFT JOIN vitals_per_encounter vp
    ON rb.Encounter_Id = vp.Encounter_Id
LEFT JOIN medications_per_encounter mp
    ON rb.Encounter_Id = mp.Encounter_Id
WHERE rb.STOP IS NOT NULL;