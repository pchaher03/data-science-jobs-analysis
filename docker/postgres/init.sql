CREATE TABLE IF NOT EXISTS raw_jobs (
    job_id VARCHAR(100) PRIMARY KEY,
    search_role VARCHAR(100),
    search_seniority VARCHAR(50),
    country_code VARCHAR(10),
    raw_title TEXT,
    company_name TEXT,
    location_display TEXT,
    category_label TEXT,
    contract_time VARCHAR(50),
    salary_min NUMERIC,
    salary_max NUMERIC,
    salary_is_predicted VARCHAR(10),
    created_at TIMESTAMP,
    description_snippet TEXT,
    redirect_url TEXT,
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);