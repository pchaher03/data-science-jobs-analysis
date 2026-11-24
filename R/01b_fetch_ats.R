library(httr2)
library(jsonlite)
library(dplyr)
library(purrr)
library(stringr)
library(DBI)
library(RPostgres)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

# Strip HTML entities and tags from full ATS descriptions
clean_html <- function(html_str) {
  if (is.null(html_str) || is.na(html_str) || html_str == "") return("")
  html_str |>
    str_replace_all("&lt;", "<") |>
    str_replace_all("&gt;", ">") |>
    str_replace_all("&amp;", "&") |>
    str_replace_all("&quot;", '"') |>
    str_replace_all("&#39;", "'") |>
    str_replace_all("<[^>]+>", " ") |>
    str_replace_all("\\s+", " ") |>
    str_trim()
}

# Map job title to one of the 4 target roles (returns NA if unrelated role)
classify_target_role <- function(title) {
  t <- tolower(title)
  if (str_detect(t, "\\b(ai engineer|artificial intelligence|generative ai|gen ai|llm)\\b")) {
    return("AI Engineer")
  }
  if (str_detect(t, "\\b(machine learning|ml engineer|mlops|deep learning|computer vision|nlp)\\b")) {
    return("ML Engineer")
  }
  if (str_detect(t, "\\b(data scientist|research scientist|applied scientist|decision scientist)\\b")) {
    return("Data Scientist")
  }
  if (str_detect(t, "\\b(data analyst|business intelligence|bi analyst|product analyst|analytics analyst)\\b")) {
    return("Data Analyst")
  }
  NA_character_
}

# Infer seniority label accurately so Senior ATS roles don't pollute Junior counts
classify_search_seniority <- function(title) {
  t <- tolower(title)
  if (str_detect(t, "\\b(intern|internship|co-op|coop|university grad|new grad|campus)\\b")) {
    return("Intern")
  }
  if (str_detect(t, "\\b(senior|sr\\.?|staff|principal|lead|manager|director|head of|vp|iii|iv)\\b")) {
    return("Senior")
  }
  "Junior"
}

# 1. Expanded Greenhouse company board slugs (~90 tech, data, fintech, & AI employers)
greenhouse_boards <- unique(c(
  "databricks", "anthropic", "scaleai", "huggingface", "cohere",
  "stripe", "airbnb", "cloudflare", "figma", "notion",
  "duolingo", "instacart", "doordash", "coinbase", "robinhood",
  "pinterest", "dropbox", "asana", "gitlab", "hashicorp",
  "weightsandbiases", "anyscale", "togetherai", "runwayml", "midjourney",
  "plaid", "brex", "chime", "affirm", "gusto",
  "reddit", "discord", "twitch", "spotify", "uber",
  "datadog", "mongodb", "elastic", "confluent", "okta",
  "zillow", "lyft", "block", "squareup", "roblox",
  "coursera", "udemy", "grammarly", "twilio", "zendesk",
  "box", "hubspot", "toast", "waymo", "aurora",
  "cruise", "verkada", "canva", "miro", "amplitude",
  "mixpanel", "segment", "braze", "klaviyo", "shopify",
  "airtable", "webflow", "intercom", "calendly", "lattice",
  "benchling", "tempus", "flatironhealth", "oscar", "ro",
  "wealthfront", "betterment", "sofi", "marqeta", "adyen",
  "klarna", "wise", "monzo", "revolut", "n26"
))

# 2. Expanded Lever company board slugs (~35 companies)
lever_boards <- unique(c(
  "palantir", "mistral", "adept", "imbue", "perplexity",
  "ramp", "mercury", "deel", "airtable", "webflow",
  "zoox", "nuro", "anduril", "verkada", "samsara",
  "netflix", "plaid", "wealthfront", "benchling", "lattice",
  "color", "ro", "dnb", "twitch", "niantic",
  "unity", "epicgames", "riotgames", "patreon", "substack",
  "medium", "automattic", "postman", "docker", "circleci"
))

# 3. Ashby ATS company board slugs (~35 AI & modern tech employers)
ashby_boards <- unique(c(
  "openai", "snowflake", "linear", "notion", "ramp",
  "replit", "vanta", "deel", "elevenlabs", "cognition",
  "harvey", "pinecone", "modal", "baseten", "perplexity",
  "vercel", "supabase", "posthog", "dbt-labs", "fivetran",
  "hex", "census", "hightouch", "montecarlo", "atlan",
  "glean", "writer", "jasper", "synthesia", "character",
  "inflection", "adept", "crusoe", "lambda", "together"
))

fetch_greenhouse_board <- function(slug) {
  tryCatch({
    url <- sprintf("https://boards-api.greenhouse.io/v1/boards/%s/jobs?content=true", slug)
    resp <- request(url) |>
      req_error(is_error = \(resp) FALSE) |>
      req_timeout(60) |>
      req_perform()

    if (resp_status(resp) != 200) return(NULL)
    body <- resp_body_json(resp, simplifyVector = FALSE)
    jobs <- body$jobs
    if (length(jobs) == 0) return(NULL)

    map_dfr(jobs, function(j) {
      title <- as.character(j$title %||% "")
      role <- classify_target_role(title)
      if (is.na(role)) return(NULL)

      desc <- clean_html(as.character(j$content %||% ""))
      tibble(
        job_id              = paste0("gh_", slug, "_", as.character(j$id %||% "")),
        search_role         = role,
        search_seniority    = classify_search_seniority(title),
        country_code        = "us",
        raw_title           = title,
        company_name        = str_to_title(slug),
        location_display    = as.character(j$location$name %||% "Not Specified"),
        category_label      = "ATS - Greenhouse",
        contract_time       = "full_time",
        salary_min          = NA_real_,
        salary_max          = NA_real_,
        salary_is_predicted = "0",
        created_at          = substr(as.character(j$updated_at %||% ""), 1, 19),
        description_snippet = desc,
        redirect_url        = as.character(j$absolute_url %||% NA_character_)
      )
    })
  }, error = function(e) {
    message(sprintf("  [Greenhouse] %-18s -> skipped (%s)", slug, conditionMessage(e)))
    NULL
  })
}

fetch_lever_board <- function(slug) {
  tryCatch({
    url <- sprintf("https://api.lever.co/v0/postings/%s?mode=json", slug)
    resp <- request(url) |>
      req_error(is_error = \(resp) FALSE) |>
      req_timeout(60) |>
      req_perform()

    if (resp_status(resp) != 200) return(NULL)
    jobs <- resp_body_json(resp, simplifyVector = FALSE)
    if (length(jobs) == 0) return(NULL)

    map_dfr(jobs, function(j) {
      title <- as.character(j$text %||% "")
      role <- classify_target_role(title)
      if (is.na(role)) return(NULL)

      desc_parts <- paste(
        clean_html(as.character(j$description %||% "")),
        clean_html(as.character(j$additional %||% "")),
        paste(map_chr(j$lists %||% list(), ~ paste(.x$text %||% "", clean_html(.x$content %||% ""))), collapse = " ")
      )

      created_ts <- NA_character_
      if (!is.null(j$createdAt) && is.numeric(j$createdAt)) {
        created_ts <- format(as.POSIXct(j$createdAt / 1000, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d %H:%M:%S")
      }

      tibble(
        job_id              = paste0("lv_", slug, "_", as.character(j$id %||% "")),
        search_role         = role,
        search_seniority    = classify_search_seniority(title),
        country_code        = "us",
        raw_title           = title,
        company_name        = str_to_title(slug),
        location_display    = as.character(j$categories$location %||% "Not Specified"),
        category_label      = "ATS - Lever",
        contract_time       = as.character(j$categories$commitment %||% "full_time"),
        salary_min          = NA_real_,
        salary_max          = NA_real_,
        salary_is_predicted = "0",
        created_at          = created_ts %||% NA_character_,
        description_snippet = str_squish(desc_parts),
        redirect_url        = as.character(j$hostedUrl %||% NA_character_)
      )
    })
  }, error = function(e) {
    message(sprintf("  [Lever]      %-18s -> skipped (%s)", slug, conditionMessage(e)))
    NULL
  })
}

fetch_ashby_board <- function(slug) {
  tryCatch({
    url <- sprintf("https://api.ashbyhq.com/posting-api/job-board/%s?includeCompensation=true", slug)
    resp <- request(url) |>
      req_error(is_error = \(resp) FALSE) |>
      req_timeout(60) |>
      req_perform()

    if (resp_status(resp) != 200) return(NULL)
    body <- resp_body_json(resp, simplifyVector = FALSE)
    jobs <- body$jobs
    if (length(jobs) == 0) return(NULL)

    map_dfr(jobs, function(j) {
      title <- as.character(j$title %||% "")
      role <- classify_target_role(title)
      if (is.na(role)) return(NULL)

      desc <- as.character(j$descriptionPlain %||% "")
      if (desc == "") desc <- clean_html(as.character(j$descriptionHtml %||% ""))

      sal_min <- NA_real_
      sal_max <- NA_real_
      comp_tiers <- j$compensation$compensationTierSummary %||% NULL
      if (!is.null(j$compensation$summaryComponents) && length(j$compensation$summaryComponents) > 0) {
        comp <- j$compensation$summaryComponents[[1]]
        sal_min <- as.numeric(comp$minValue %||% NA_real_)
        sal_max <- as.numeric(comp$maxValue %||% NA_real_)
      }

      tibble(
        job_id              = paste0("ab_", slug, "_", as.character(j$id %||% "")),
        search_role         = role,
        search_seniority    = classify_search_seniority(title),
        country_code        = "us",
        raw_title           = title,
        company_name        = str_to_title(slug),
        location_display    = as.character(j$location %||% "Not Specified"),
        category_label      = "ATS - Ashby",
        contract_time       = tolower(as.character(j$employmentType %||% "full_time")),
        salary_min          = sal_min,
        salary_max          = sal_max,
        salary_is_predicted = "0",
        created_at          = substr(as.character(j$publishedAt %||% ""), 1, 19),
        description_snippet = str_squish(desc),
        redirect_url        = as.character(j$jobUrl %||% NA_character_)
      )
    })
  }, error = function(e) {
    message(sprintf("  [Ashby]      %-18s -> skipped (%s)", slug, conditionMessage(e)))
    NULL
  })
}

fetch_themuse_page <- function(page = 1, level = "Entry Level") {
  tryCatch({
    resp <- request("https://www.themuse.com/api/public/jobs") |>
      req_url_query(
        category = "Data and Analytics",
        category = "Data Science",
        level    = level,
        page     = page
      ) |>
      req_error(is_error = \(resp) FALSE) |>
      req_timeout(60) |>
      req_perform()

    if (resp_status(resp) != 200) return(NULL)
    body <- resp_body_json(resp, simplifyVector = FALSE)
    results <- body$results
    if (length(results) == 0) return(NULL)

    map_dfr(results, function(j) {
      title <- as.character(j$name %||% "")
      role <- classify_target_role(title)
      if (is.na(role)) return(NULL)

      loc <- if (length(j$locations) > 0) as.character(j$locations[[1]]$name %||% "Not Specified") else "Not Specified"
      sen <- if (level == "Internship") "Intern" else classify_search_seniority(title)

      tibble(
        job_id              = paste0("muse_", as.character(j$id %||% "")),
        search_role         = role,
        search_seniority    = sen,
        country_code        = "us",
        raw_title           = title,
        company_name        = as.character(j$company$name %||% "Not Specified"),
        location_display    = loc,
        category_label      = "API - The Muse",
        contract_time       = "full_time",
        salary_min          = NA_real_,
        salary_max          = NA_real_,
        salary_is_predicted = "0",
        created_at          = substr(as.character(j$publication_date %||% ""), 1, 19),
        description_snippet = clean_html(as.character(j$contents %||% "")),
        redirect_url        = as.character(j$refs$landing_page %||% NA_character_)
      )
    })
  }, error = function(e) {
    message(sprintf("  [The Muse]   page %-3d (%s) -> skipped (%s)", page, level, conditionMessage(e)))
    NULL
  })
}

insert_jobs <- function(con, df) {
  if (is.null(df) || nrow(df) == 0) return(0L)
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

main <- function() {
  env_path <- Sys.getenv("ENV_FILE", unset = "/home/rstudio/project/.env")
  if (file.exists(env_path)) readRenviron(env_path)

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

  total_new <- 0L

  message("--- 1/4 Fetching Greenhouse ATS boards ---")
  for (slug in greenhouse_boards) {
    df <- fetch_greenhouse_board(slug)
    n_ins <- insert_jobs(con, df)
    if (!is.null(df) && nrow(df) > 0) {
      message(sprintf("  [Greenhouse] %-18s -> %d matched, %d new inserted", slug, nrow(df), n_ins))
    }
    total_new <- total_new + n_ins
    Sys.sleep(0.3)
  }

  message("--- 2/4 Fetching Lever ATS boards ---")
  for (slug in lever_boards) {
    df <- fetch_lever_board(slug)
    n_ins <- insert_jobs(con, df)
    if (!is.null(df) && nrow(df) > 0) {
      message(sprintf("  [Lever]      %-18s -> %d matched, %d new inserted", slug, nrow(df), n_ins))
    }
    total_new <- total_new + n_ins
    Sys.sleep(0.3)
  }

  message("--- 3/4 Fetching Ashby ATS boards ---")
  for (slug in ashby_boards) {
    df <- fetch_ashby_board(slug)
    n_ins <- insert_jobs(con, df)
    if (!is.null(df) && nrow(df) > 0) {
      message(sprintf("  [Ashby]      %-18s -> %d matched, %d new inserted", slug, nrow(df), n_ins))
    }
    total_new <- total_new + n_ins
    Sys.sleep(0.3)
  }

  message("--- 4/4 Fetching The Muse Public API (Entry Level & Internship) ---")
  for (lvl in c("Entry Level", "Internship")) {
    for (p in 1:15) {
      df <- fetch_themuse_page(page = p, level = lvl)
      if (is.null(df)) break
      n_ins <- insert_jobs(con, df)
      message(sprintf("  [The Muse]   %-12s p.%-2d -> %d matched, %d new inserted", lvl, p, nrow(df), n_ins))
      total_new <- total_new + n_ins
      Sys.sleep(0.5)
    }
  }

  counts <- dbGetQuery(con, "
    SELECT
      COUNT(*) AS total_rows,
      COUNT(*) FILTER (WHERE LENGTH(COALESCE(description_snippet, '')) >= 1000) AS full_text_rows
    FROM raw_jobs;
  ")
  message(sprintf(
    "Done! Added %.0f new rows. Total in raw_jobs: %.0f | Full-text (>=1,000 chars): %.0f",
    total_new, as.numeric(counts$total_rows), as.numeric(counts$full_text_rows)
  ))
}

main()