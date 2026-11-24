FROM rocker/tidyverse:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN R -e "install.packages(c('httr2', 'jsonlite', 'DBI', 'RPostgres', 'dotenv'), repos='https://packagemanager.posit.co/cran/__linux__/jammy/latest')"

WORKDIR /home/rstudio/project