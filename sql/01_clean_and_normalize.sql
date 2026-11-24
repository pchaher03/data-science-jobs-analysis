-- =============================================================================
-- 01_clean_and_normalize.sql
-- Deduplicates raw_jobs, standardizes role & seniority taxonomies, normalizes
-- salaries, and extracts binary technical skill & barrier flags via regex.
-- =============================================================================

DROP TABLE IF EXISTS clean_jobs CASCADE;

CREATE TABLE clean_jobs AS
WITH ranked_raw AS (
    SELECT
        job_id,
        search_role,
        search_seniority,
        country_code,
        TRIM(REGEXP_REPLACE(raw_title, '\s+', ' ', 'g')) AS clean_title,
        COALESCE(NULLIF(TRIM(company_name), ''), 'Unknown') AS company_name,
        COALESCE(NULLIF(TRIM(location_display), ''), 'Unknown') AS location_display,
        COALESCE(NULLIF(TRIM(category_label), ''), 'Uncategorized') AS category_label,
        COALESCE(NULLIF(TRIM(contract_time), ''), 'not_specified') AS contract_time,
        salary_min,
        salary_max,
        salary_is_predicted,
        created_at,
        TRIM(REGEXP_REPLACE(COALESCE(description_snippet, ''), '\s+', ' ', 'g')) AS description_clean,
        redirect_url,
        ingested_at,
        -- Deduplicate same job reposted under different search queries or job_ids
        ROW_NUMBER() OVER (
            PARTITION BY
                LOWER(COALESCE(NULLIF(TRIM(company_name), ''), 'unknown')),
                LOWER(TRIM(REGEXP_REPLACE(raw_title, '\s+', ' ', 'g'))),
                LOWER(COALESCE(NULLIF(TRIM(location_display), ''), 'unknown'))
            ORDER BY
                (salary_min IS NOT NULL) DESC,
                LENGTH(COALESCE(description_snippet, '')) DESC,
                created_at DESC NULLS LAST,
                job_id ASC
        ) AS dup_rank
    FROM raw_jobs
    WHERE job_id IS NOT NULL
      AND TRIM(raw_title) <> ''
      AND LENGTH(COALESCE(description_snippet, '')) >= 1000
),
deduped AS (
    SELECT *
    FROM ranked_raw
    WHERE dup_rank = 1
),
enriched AS (
    SELECT
        job_id,
        search_role,
        search_seniority,
        country_code,
        clean_title AS raw_title,
        company_name,
        location_display,
        category_label,
        contract_time,
        created_at,
        DATE(created_at) AS posted_date,
        description_clean AS description_snippet,
        LENGTH(description_clean) AS description_length,
        redirect_url,

        -- ---------------------------------------------------------------------
        -- 1. Normalized Role Track (title-first classification, fallback to query)
        -- ---------------------------------------------------------------------
        CASE
            WHEN clean_title ~* '\m(ai engineer|artificial intelligence|generative ai|gen ai|llm|machine learning.*ai)\M'
                THEN 'AI Engineer'
            WHEN clean_title ~* '\m(machine learning|ml engineer|mlops|deep learning|computer vision|nlp engineer)\M'
                THEN 'ML Engineer'
            WHEN clean_title ~* '\m(data scientist|research scientist|applied scientist|decision scientist)\M'
                THEN 'Data Scientist'
            WHEN clean_title ~* '\m(data analyst|business intelligence|bi analyst|analytics analyst|reporting analyst|product analyst|marketing analyst|financial analyst)\M'
                THEN 'Data Analyst'
            WHEN search_role = 'Machine Learning Engineer' THEN 'ML Engineer'
            ELSE search_role
        END AS normalized_role,

        -- ---------------------------------------------------------------------
        -- 2. Seniority Tier (detects mislabeled Senior/Mid roles in Junior searches)
        -- ---------------------------------------------------------------------
        CASE
            WHEN clean_title ~* '\m(intern|internship|co-op|coop|student|summer analyst)\M'
                 OR search_seniority = 'Intern'
                THEN 'Intern'
            WHEN clean_title ~* '\m(senior|sr\.?|lead|principal|staff|director|manager|head of|vp|iii|iv)\M'
                 OR (clean_title || ' ' || description_clean) ~* '\m([4-9]|[1-9][0-9])\+?\s*(years?|yrs?)\s*(of)?\s*(experience|exp)?\M'
                THEN 'Mid/Senior Mislabeled'
            ELSE 'Junior / Entry-Level'
        END AS seniority_tier,

        -- ---------------------------------------------------------------------
        -- 3. Work Mode (Remote / Hybrid / On-Site or Unspecified)
        -- ---------------------------------------------------------------------
        CASE
            WHEN (clean_title || ' ' || location_display || ' ' || description_clean) ~* '\m(remote|work from home|wfh|telecommute|anywhere)\M'
                THEN 'Remote'
            WHEN (clean_title || ' ' || location_display || ' ' || description_clean) ~* '\m(hybrid)\M'
                THEN 'Hybrid'
            ELSE 'On-Site / Not Specified'
        END AS work_mode,

        -- ---------------------------------------------------------------------
        -- 4. Salary Normalization
        -- ---------------------------------------------------------------------
        CASE WHEN salary_min IS NOT NULL AND salary_min > 0 THEN ROUND(salary_min, 2) ELSE NULL END AS salary_min,
        CASE WHEN salary_max IS NOT NULL AND salary_max > 0 THEN ROUND(salary_max, 2) ELSE NULL END AS salary_max,
        CASE
            WHEN salary_min IS NOT NULL AND salary_min > 0 AND salary_max IS NOT NULL AND salary_max > 0
                THEN ROUND((salary_min + salary_max) / 2.0, 2)
            WHEN salary_min IS NOT NULL AND salary_min > 0
                THEN ROUND(salary_min, 2)
            WHEN salary_max IS NOT NULL AND salary_max > 0
                THEN ROUND(salary_max, 2)
            ELSE NULL
        END AS salary_midpoint,
        CASE WHEN (salary_min IS NOT NULL AND salary_min > 0) OR (salary_max IS NOT NULL AND salary_max > 0) THEN 1 ELSE 0 END AS has_listed_salary,
        CASE WHEN salary_is_predicted = '1' THEN 1 ELSE 0 END AS is_predicted_salary,

        -- ---------------------------------------------------------------------
        -- 5. Experience & Education Barriers
        -- ---------------------------------------------------------------------
        CASE
            WHEN (clean_title || ' ' || description_clean) ~* '\m([3-9]|[1-9][0-9])\+?\s*(years?|yrs?)\M'
                THEN '3+ Years'
            WHEN (clean_title || ' ' || description_clean) ~* '\m2\+?\s*(years?|yrs?)\M'
                THEN '2+ Years'
            WHEN (clean_title || ' ' || description_clean) ~* '\m(0\s*[-–to]+\s*[12]|1\+?\s*(year|yr)|entry[- ]level|no experience|recent graduate|new grad)\M'
                THEN '0-1 Years / Entry'
            ELSE 'Not Specified'
        END AS experience_tier,

        CASE
            WHEN description_clean ~* '\m(ph\.?d|doctorate)\M'
                THEN 'PhD'
            WHEN description_clean ~* '\m(master''?s?|m\.?s\.?|mba|graduate degree)\M'
                THEN 'Master''s'
            WHEN description_clean ~* '\m(bachelor''?s?|b\.?s\.?|b\.?a\.?|undergraduate degree|4-year degree)\M'
                THEN 'Bachelor''s'
            ELSE 'Not Specified'
        END AS degree_tier,

        -- ---------------------------------------------------------------------
        -- 6. Technical Skill Flags (1 = Mentioned in Title or Description, 0 = No)
        -- ---------------------------------------------------------------------
        -- Programming & Querying
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(sql|postgresql|mysql|t-sql|pl/sql|snowflake|bigquery|redshift)\M' THEN 1 ELSE 0 END AS skill_sql,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(python|pandas|numpy)\M' THEN 1 ELSE 0 END AS skill_python,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '(\mr\M|\br studio\b|\brstudio\b|\btidyverse\b)' THEN 1 ELSE 0 END AS skill_r,

        -- BI & Spreadsheets
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(tableau)\M' THEN 1 ELSE 0 END AS skill_tableau,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(power\s*bi|powerbi|dax)\M' THEN 1 ELSE 0 END AS skill_powerbi,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(excel|spreadsheets?|vlookup|pivot tables?)\M' THEN 1 ELSE 0 END AS skill_excel,

        -- ML & AI Frameworks
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(scikit-learn|sklearn)\M' THEN 1 ELSE 0 END AS skill_sklearn,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(pytorch)\M' THEN 1 ELSE 0 END AS skill_pytorch,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(tensorflow|keras)\M' THEN 1 ELSE 0 END AS skill_tensorflow,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(llm|large language models?|openai|langchain|llamaindex|rag|generative ai|gen ai|hugging\s*face|transformers)\M' THEN 1 ELSE 0 END AS skill_llm_genai,

        -- Cloud & Engineering
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(aws|amazon web services|sagemaker|s3|ec2)\M' THEN 1 ELSE 0 END AS skill_aws,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(gcp|google cloud|vertex ai)\M' THEN 1 ELSE 0 END AS skill_gcp,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(azure|databricks)\M' THEN 1 ELSE 0 END AS skill_azure,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(docker|kubernetes|k8s)\M' THEN 1 ELSE 0 END AS skill_docker_k8s,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(git|github|gitlab|ci/cd)\M' THEN 1 ELSE 0 END AS skill_git,
        CASE WHEN (clean_title || ' ' || description_clean) ~* '\m(spark|pyspark|hadoop|airflow|dbt|etl)\M' THEN 1 ELSE 0 END AS skill_data_eng
    FROM deduped
)
SELECT
    *,
    -- Composite domain flags for executive summaries
    GREATEST(skill_tableau, skill_powerbi, skill_excel) AS has_any_bi_tool,
    GREATEST(skill_sklearn, skill_pytorch, skill_tensorflow, skill_llm_genai) AS has_any_ml_ai,
    GREATEST(skill_aws, skill_gcp, skill_azure, skill_docker_k8s, skill_data_eng) AS has_any_cloud_mlops
FROM enriched;

-- Add primary key and helpful indexes for analytical queries
ALTER TABLE clean_jobs ADD PRIMARY KEY (job_id);
CREATE INDEX idx_clean_jobs_role_seniority ON clean_jobs (normalized_role, seniority_tier);