# Project Vision & Functional Requirements

## 1. Project Vision

To eliminate guesswork for aspiring data and AI professionals by transforming live job-market data into an evidence-based career roadmap. Using a containerized **R → PostgreSQL → SQL → Quarto** pipeline ingesting from the official **Adzuna Jobs REST API** and public ATS JSON endpoints (**Greenhouse, Lever, Ashby, and The Muse**), this project audits entry-level and internship postings across four target roles—**Data Analyst**, **Data Scientist**, **Machine Learning Engineer**, and **AI Engineer**—to uncover which track offers the most accessible entry point and which technical stacks employers genuinely require.

### Core Research Questions
1. **Role Demand & Accessibility:** How do verified entry-level and internship volumes compare across Data Analyst, Data Scientist, ML Engineer, and AI Engineer titles once mislabeled senior roles are removed?
2. **Skill Overlap vs. Specialization:** Which technical skills are universal across all four paths, and which tools define each specialization when full descriptions are parsed?
3. **Credential & Experience Barriers:** What proportion of junior/intern postings require a Master’s/PhD or 2+ years of prior experience?
4. **Compensation & Work Mode:** How do disclosed salary ranges and remote/hybrid availability differ across the four career tracks?

---

## 2. Functional Requirements

### FR-1: Containerized Infrastructure (`docker-compose.yml` & `docker/`)
* **FR-1.1 Single-Command Orchestration:** The entire analytical environment (PostgreSQL 16 + Rocker R/Quarto container) shall launch reproducibly via `docker compose up --build -d`.
* **FR-1.2 Database Initialization:** The PostgreSQL container (`docker/postgres/Dockerfile`) shall automatically initialize the `raw_jobs` landing table (`docker/postgres/init.sql`) on first startup.
* **FR-1.3 Isolated Compute & Reporting Environment:** The Rocker container (`docker/rocker/Dockerfile`) shall provide pinned versions of R, `tidyverse`, `DBI`/`RPostgres`, `httr2`, and `Quarto` with local volume mounts syncing outputs directly to `docs/` and `data/processed/`.

### FR-2: Multi-Source API & ATS Ingestion (`R/01_fetch_adzuna.R` & `R/01b_fetch_ats.R`)
* **FR-2.1 Official API & Public JSON Collection:** All postings shall be collected strictly via official REST APIs (Adzuna) and public ATS JSON feeds (Greenhouse, Lever, Ashby, The Muse) using idempotent `ON CONFLICT (job_id) DO NOTHING` inserts into `raw_jobs`, with zero unauthorized HTML web scraping.
* **FR-2.2 Four-Role Multi-Query Coverage:** Ingestion scripts shall target *Data Analyst*, *Data Scientist*, *Machine Learning Engineer*, and *AI Engineer* across Junior/Entry-Level and Internship roles.
* **FR-2.3 Rate-Limit & Credential Security:** Collectors shall enforce request delays (`Sys.sleep()`), log HTTP status responses, and read credentials (`ADZUNA_APP_ID`, `ADZUNA_APP_KEY`) exclusively from an untracked `.env` file.

### FR-3: Full-Text Quality Gate & SQL Feature Engineering (`sql/01_clean_and_normalize.sql`)
* **FR-3.1 Full-Text Quality Gate:** While `raw_jobs` preserves the full multi-source archive, `clean_jobs` shall enforce `LENGTH(description_snippet) >= 1000` to exclude truncated ~250-character API snippets that cause systematic false negatives during keyword extraction.
* **FR-3.2 Window-Function Deduplication:** SQL transformations shall retain one canonical record per `(company_name, normalized_title, location_display)`, prioritizing rows with disclosed salaries and longer descriptions.
* **FR-3.3 Role & Seniority Taxonomy:** Raw titles shall be classified into the four canonical tracks (`Data Analyst`, `Data Scientist`, `ML Engineer`, `AI Engineer`) and three seniority tiers (`Intern`, `Junior / Entry-Level`, `Mid/Senior Mislabeled`).
* **FR-3.4 SQL Regex Skill & Barrier Extraction:** PostgreSQL POSIX regular expressions (`~*`) shall generate binary flags (`1`/`0`) across 16 technical skills (Programming, BI/Spreadsheets, ML/AI Frameworks, Cloud/MLOps), minimum experience tiers, degree requirements, and work modes.

### FR-4: Analytical Query Layer & Export (`sql/02_market_analysis.sql` & `R/02_export_for_tableau.R`)
* **FR-4.1 Cross-Role Analytical Views:** SQL views (`vw_role_summary`, `vw_skill_matrix`, `vw_accessibility_barriers`) shall compute skill demand percentages, experience/credential barriers, and median listed salaries grouped by `normalized_role` and `seniority_tier`.
* **FR-4.2 Tableau & Reporting Exports:** `R/02_export_for_tableau.R` shall export `jobs_cleaned.csv`, `role_summary.csv`, and `skill_matrix.csv` into `data/processed/`.

### FR-5: Interactive Visualization & Reporting (`docs/` & Tableau Public)
* **FR-5.1 Reproducible Quarto Deliverables:** `reports/case_study_report.qmd` shall render a self-contained HTML case study (`docs/case_study_report.html`) inside the Rocker container.
* **FR-5.2 Interactive Tableau Dashboard:** An interactive **Tableau Public** dashboard shall display executive KPIs, a Role-by-Skill Heatmap, an Experience Barrier breakdown, and Salary/Work-Mode comparisons with dynamic role and seniority filters.

---

## 3. Non-Functional Requirements & Data Governance

* **NFR-1 Ethical Compliance:** Data collection exclusively utilizes official developer APIs and public ATS JSON endpoints in compliance with platform terms of service, avoiding unauthorized web scraping.
* **NFR-2 Reproducibility:** All transformations from database initialization and ingestion to SQL cleaning and Quarto HTML rendering execute deterministically via Docker Compose.
* **NFR-3 Transparency of Limitations:** Documentation explicitly discloses the sample trade-off of the $\ge 1{,}000$-character quality gate: excluding truncated Adzuna snippets prevents false-negative skill counts (`n = 636` full-text postings retained in `clean_jobs`), but shifts the sample toward tech and AI employers using public ATS boards and yields small cell sizes for traditional Data Analyst roles (`n = 8` in-scope) and employer-disclosed salaries.