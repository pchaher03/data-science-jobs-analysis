library(DBI)
library(RPostgres)
library(dplyr)
library(stringr)

env_path <- "/home/rstudio/project/.env"
if (file.exists(env_path)) {
  readRenviron(env_path)
}

con <- dbConnect(
  RPostgres::Postgres(),
  host     = Sys.getenv("PGHOST", unset = "db"),
  port     = as.integer(Sys.getenv("PGPORT", unset = "5432")),
  user     = Sys.getenv("POSTGRES_USER", unset = "analyst"),
  password = Sys.getenv("POSTGRES_PASSWORD", unset = "analyst_pass"),
  dbname   = Sys.getenv("POSTGRES_DB", unset = "job_market_db"),
  bigint   = "numeric"
)

raw_df <- dbGetQuery(con, "
  SELECT
    job_id,
    search_role,
    search_seniority,
    raw_title,
    company_name,
    category_label,
    description_snippet
  FROM raw_jobs;
") |> as_tibble()

dbDisconnect(con)

# ---------------------------------------------------------------------------
# PART A: Measure character lengths (strlen) across sources
# ---------------------------------------------------------------------------
raw_lengths <- raw_df |>
  mutate(
    # Tag whether the row came from Adzuna or an ATS (Greenhouse/Lever)
    source = if_else(str_starts(job_id, "gh_|lv_"), "ATS (Greenhouse/Lever)", "Adzuna API"),
    # nchar() or str_length() counts characters (equivalent to SQL LENGTH())
    char_len = str_length(coalesce(description_snippet, "")),
    # Bucket the lengths to see the distribution clearly
    length_bucket = case_when(
      char_len == 0   ~ "0 (Empty)",
      char_len < 300  ~ "1-299 chars (Truncated snippet)",
      char_len < 1000 ~ "300-999 chars (Short summary)",
      TRUE            ~ "1,000+ chars (Full job post)"
    )
  )

# Summary statistics of string length by source
length_summary <- raw_lengths |>
  group_by(source) |>
  summarise(
    total_rows  = n(),
    min_chars   = min(char_len),
    median_chars = median(char_len),
    mean_chars  = round(mean(char_len), 0),
    max_chars   = max(char_len),
    .groups     = "drop"
  )

print("=== String Length Summary by Source ===")
print(length_summary)

# Count rows per length bucket
print("=== Breakdown by Length Bucket ===")
print(raw_lengths |> count(source, length_bucket))

# ---------------------------------------------------------------------------
# PART B: Print real examples of short vs. long descriptions
# ---------------------------------------------------------------------------

# Example 1: Short truncated Adzuna snippet (< 300 chars)
short_examples <- raw_lengths |>
  filter(source == "Adzuna API", char_len > 0) |>
  slice_sample(n = 3)

cat("\n=== 3 SHORT ADZUNA EXAMPLES ===\n")
for (i in seq_len(nrow(short_examples))) {
  cat(sprintf(
    "\n[%d] %s | %s (%d chars)\nText: %s\n",
    i,
    short_examples$raw_title[i],
    short_examples$company_name[i],
    short_examples$char_len[i],
    short_examples$description_snippet[i]
  ))
}

# Example 2: Full ATS description (1,000+ chars, truncated to first 600 chars for console readability)
long_examples <- raw_lengths |>
  filter(source == "ATS (Greenhouse/Lever)", char_len >= 1000) |>
  slice_sample(n = 2)

cat("\n=== 2 FULL ATS EXAMPLES (First 600 chars shown) ===\n")
for (i in seq_len(nrow(long_examples))) {
  cat(sprintf(
    "\n[%d] %s | %s (Total length: %d chars)\nPreview: %s\n",
    i,
    long_examples$raw_title[i],
    long_examples$company_name[i],
    long_examples$char_len[i],
    str_trunc(long_examples$description_snippet[i], width = 600)
  ))
}

# ---------------------------------------------------------------------------
# PART C: Open an interactive spreadsheet view in RStudio!
# ---------------------------------------------------------------------------
raw_lengths |>
  select(source, search_role, raw_title, company_name, char_len, description_snippet) |>
  arrange(desc(char_len)) |>
  View(title = "Raw_Descriptions_Explorer")