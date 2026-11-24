-- =============================================================================
-- 02_market_analysis.sql
-- Analytical views & summary queries for Quarto reporting and Tableau Public
-- =============================================================================

-- 1. Executive Role & Seniority Summary (Core Table for README & Report)
CREATE OR REPLACE VIEW vw_role_summary AS
SELECT
    normalized_role,
    seniority_tier,
    COUNT(*) AS total_postings,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS share_of_market_pct,
    ROUND(AVG(skill_sql) * 100, 1) AS pct_sql,
    ROUND(AVG(skill_python) * 100, 1) AS pct_python,
    ROUND(AVG(skill_r) * 100, 1) AS pct_r,
    ROUND(AVG(has_any_bi_tool) * 100, 1) AS pct_bi_tools,
    ROUND(AVG(has_any_ml_ai) * 100, 1) AS pct_ml_ai,
    ROUND(AVG(has_any_cloud_mlops) * 100, 1) AS pct_cloud_mlops,
    SUM(has_listed_salary) AS salary_disclosed_count,
    ROUND(AVG(has_listed_salary) * 100, 1) AS salary_transparency_pct,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY salary_midpoint)::NUMERIC, 0) AS median_salary
FROM clean_jobs
GROUP BY normalized_role, seniority_tier
ORDER BY normalized_role, seniority_tier;

-- 2. Skill Frequency Matrix Across Roles (True Entry-Level & Intern Only)
CREATE OR REPLACE VIEW vw_skill_matrix AS
SELECT
    normalized_role,
    COUNT(*) AS postings,
    ROUND(AVG(skill_sql) * 100, 1) AS sql,
    ROUND(AVG(skill_python) * 100, 1) AS python,
    ROUND(AVG(skill_r) * 100, 1) AS r_lang,
    ROUND(AVG(skill_excel) * 100, 1) AS excel,
    ROUND(AVG(skill_tableau) * 100, 1) AS tableau,
    ROUND(AVG(skill_powerbi) * 100, 1) AS power_bi,
    ROUND(AVG(skill_sklearn) * 100, 1) AS scikit_learn,
    ROUND(AVG(skill_pytorch) * 100, 1) AS pytorch,
    ROUND(AVG(skill_tensorflow) * 100, 1) AS tensorflow,
    ROUND(AVG(skill_llm_genai) * 100, 1) AS llm_genai,
    ROUND(AVG(skill_aws) * 100, 1) AS aws,
    ROUND(AVG(skill_gcp) * 100, 1) AS gcp,
    ROUND(AVG(skill_azure) * 100, 1) AS azure,
    ROUND(AVG(skill_docker_k8s) * 100, 1) AS docker_k8s,
    ROUND(AVG(skill_git) * 100, 1) AS git,
    ROUND(AVG(skill_data_eng) * 100, 1) AS spark_etl
FROM clean_jobs
WHERE seniority_tier IN ('Intern', 'Junior / Entry-Level')
GROUP BY normalized_role
ORDER BY postings DESC;

-- 3. Experience, Degree & Work-Mode Accessibility Breakdown
CREATE OR REPLACE VIEW vw_accessibility_barriers AS
SELECT
    normalized_role,
    seniority_tier,
    experience_tier,
    degree_tier,
    work_mode,
    COUNT(*) AS postings
FROM clean_jobs
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2, postings DESC;