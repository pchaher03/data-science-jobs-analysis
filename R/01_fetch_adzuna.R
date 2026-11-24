library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(DBI)
library(RPostgres)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Null-coalescing operator (built into R >= 4.4, defined here for older versions)
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Read a required environment variable; stop with a clear message if missing
get_env_req <- function(var_name, unset = "") {
  val <- trimws(Sys.getenv(var_name, unset = unset))
  if (val == "") {
    stop(sprintf("Missing required environment variable: %s", var_name), call. = FALSE)
  }
  val
}

# ---------------------------------------------------------------------------
# Configuration (all secrets come from environment variables / .env)
# ---------------------------------------------------------------------------

# Path to .env can be overridden with ENV_FILE
env_path <- Sys.getenv("ENV_FILE", unset = "/home/rstudio/project/.env")
if (file.exists(env_path)) {
  readRenviron(env_path)
}

# Secrets: NO defaults, script stops if any are missing
app_id  <- get_env_req("ADZUNA_APP_ID")
app_key <- get_env_req("ADZUNA_APP_KEY")
pg_user <- get_env_req("POSTGRES_USER")
pg_pass <- get_env_req("POSTGRES_PASSWORD")
pg_db   <- get_env_req("POSTGRES_DB")

# Non-secret settings: defaults are fine
country   <- get_env_req("ADZUNA_COUNTRY", unset = "us")
pg_host   <- get_env_req("PGHOST", unset = "db")
pg_port   <- as.integer(get_env_req("PGPORT", unset = "5432"))
max_pages <- as.integer(get_env_req("ADZUNA_MAX_PAGES", unset = "2"))

if (app_id == "your_app_id_here" || app_key == "your_app_key_here") {
  stop("Replace placeholder Adzuna credentials in .env before running.", call. = FALSE)
}

# Target matrix: 4 roles x 2 seniority levels
search_grid <- expand.grid(
  role = c("Data Analyst", "Data Scientist", "Machine Learning Engineer", "AI Engineer"),
  seniority = c("Junior", "Intern"),
  stringsAsFactors = FALSE
)

# ---------------------------------------------------------------------------
# API fetch
# ---------------------------------------------------------------------------

fetch_page <- function(role, seniority, page = 1, results_per_page = 50) {
  query_str <- paste(seniority, role)
  url <- sprintf("https://api.adzuna.com/v1/api/jobs/%s/search/%d", country, page)
  
  resp <- request(url) |>
    req_url_query(
      app_id = app_id,
      app_key = app_key,
      what = query_str,
      results_per_page = results_per_page,
      `content-type` = "application/json"
    ) |>
    req_error(is_error = \(resp) FALSE) |>
    req_perform()
  
  if (resp_status(resp) != 200) {
    warning(sprintf("HTTP %d for '%s' page %d", resp_status(resp), query_str, page))
    return(NULL)
  }
  
  body <- resp_body_json(resp, simplifyVector = FALSE)
  results <- body$results
  if (length(results) == 0) return(NULL)
  
  map_dfr(results, function(item) {
    tibble(
      job_id              = as.character(item$id %||% NA_character_),
      search_role         = role,
      search_seniority    = seniority,
      country_code        = country,
      raw_title           = as.character(item$title %||% NA_character_),
      company_name        = as.character(item$company$display_name %||% NA_character_),
      location_display    = as.character(item$location$display_name %||% NA_character_),
      category_label      = as.character(item$category$label %||% NA_character_),
      contract_time       = as.character(item$contract_time %||% NA_character_),
      salary_min          = as.numeric(item$salary_min %||% NA_real_),
      salary_max          = as.numeric(item$salary_max %||% NA_real_),
      salary_is_predicted = as.character(item$salary_is_predicted %||% NA_character_),
      created_at          = as.character(item$created %||% NA_character_),
      description_snippet = as.character(item$description %||% NA_character_),
      redirect_url        = as.character(item$redirect_url %||% NA_character_)
    )
  })
}

# ---------------------------------------------------------------------------
# Database insert
# ---------------------------------------------------------------------------

insert_jobs <- function(con, df) {
  inserted <- 0L
  for (r in seq_len(nrow(df))) {
    row <- df[r, ]
    if (is.na(row$job_id) || row$job_id == "") next
    res <- dbExecute(
      con,
      "INSERT INTO raw_jobs (
         job_id, search_role, search_seniority, country_code, raw_title,
         company_name, location_display, category_label, contract_time,
         salary_min, salary_max, salary_is_predicted, created_at,
         description_snippet, redirect_url
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,NULLIF($13,'')::TIMESTAMP,$14,$15)
       ON CONFLICT (job_id) DO NOTHING;",
      params = list(
        row$job_id, row$search_role, row$search_seniority, row$country_code, row$raw_title,
        row$company_name, row$location_display, row$category_label, row$contract_time,
        row$salary_min, row$salary_max, row$salary_is_predicted, row$created_at,
        row$description_snippet, row$redirect_url
      )
    )
    inserted <- inserted + res
  }
  inserted
}

# ---------------------------------------------------------------------------
# Main (on.exit works correctly here because it lives inside a function)
# ---------------------------------------------------------------------------

main <- function() {
  message(sprintf(
    "Connecting to Postgres -> host=%s, port=%d, user=%s, db=%s",
    pg_host, pg_port, pg_user, pg_db
  ))
  
  con <- dbConnect(
    RPostgres::Postgres(),
    host     = pg_host,
    port     = pg_port,
    user     = pg_user,
    password = pg_pass,
    dbname   = pg_db
  )
  on.exit(dbDisconnect(con), add = TRUE)
  
  stopifnot(dbIsValid(con))
  message("PostgreSQL connection valid! Starting Adzuna API fetch...")
  
  for (i in seq_len(nrow(search_grid))) {
    role      <- search_grid$role[i]
    seniority <- search_grid$seniority[i]
    message(sprintf("Fetching: %s %s ...", seniority, role))
    
    for (p in seq_len(max_pages)) {
      df <- fetch_page(role, seniority, page = p)
      if (is.null(df) || nrow(df) == 0) break
      
      inserted <- insert_jobs(con, df)
      message(sprintf("  Page %d -> %d fetched, %d new rows inserted", p, nrow(df), inserted))
      Sys.sleep(1.2) # Respect API rate limits
    }
  }
  
  total_rows <- as.numeric(dbGetQuery(con, "SELECT COUNT(*) AS n FROM raw_jobs;")$n)
  message(sprintf("Done! Total rows currently in raw_jobs: %.0f", total_rows))
  invisible(total_rows)
}

main()