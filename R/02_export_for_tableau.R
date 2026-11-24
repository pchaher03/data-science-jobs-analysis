library(DBI)
library(RPostgres)
library(readr)
library(dplyr)

main <- function() {
  env_path <- Sys.getenv("ENV_FILE", unset = "/home/rstudio/project/.env")
  if (file.exists(env_path)) {
    readRenviron(env_path)
  }
  
  con <- dbConnect(
    RPostgres::Postgres(),
    host     = trimws(Sys.getenv("PGHOST", unset = "db")),
    port     = as.integer(trimws(Sys.getenv("PGPORT", unset = "5432"))),
    user     = trimws(Sys.getenv("POSTGRES_USER", unset = "analyst")),
    password = trimws(Sys.getenv("POSTGRES_PASSWORD", unset = "analyst_pass")),
    dbname   = trimws(Sys.getenv("POSTGRES_DB", unset = "job_market_db")),
    bigint   = "numeric"
  )
  on.exit(dbDisconnect(con), add = TRUE)
  
  stopifnot(dbIsValid(con))
  
  out_dir <- "/home/rstudio/project/data/processed"
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  
  # 1. Export full cleaned dataset for Tableau Public
  clean_jobs <- dbGetQuery(
    con,
    "SELECT * FROM clean_jobs ORDER BY normalized_role, seniority_tier, posted_date DESC;"
  )
  write_csv(clean_jobs, file.path(out_dir, "jobs_cleaned.csv"), na = "")
  
  # 2. Export pre-aggregated views for Tableau heatmaps & Quarto tables
  role_summary <- dbGetQuery(con, "SELECT * FROM vw_role_summary;")
  skill_matrix <- dbGetQuery(con, "SELECT * FROM vw_skill_matrix;")
  
  write_csv(role_summary, file.path(out_dir, "role_summary.csv"), na = "")
  write_csv(skill_matrix, file.path(out_dir, "skill_matrix.csv"), na = "")
  
  message(sprintf("Exported %.0f rows to data/processed/jobs_cleaned.csv", nrow(clean_jobs)))
  print(role_summary)
  invisible(list(clean_jobs = clean_jobs, role_summary = role_summary, skill_matrix = skill_matrix))
}

main()