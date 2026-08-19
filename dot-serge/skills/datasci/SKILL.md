---
name: datasci
description: Data-science brain — acquire data (scraping, APIs, files), wrangle and analyze it with pandas/scipy statistical care, and present it (charts, tables, reports) as finished deliverables. Deterministic local tooling, $0.
whenToUse: Use whenever the deliverable is built FROM data — "scrape X", "pull the data from", "analyze this CSV/JSON/logs", "clean this dataset", statistics on anything, "make a chart/graph/plot/dashboard", trends, correlations, aggregations, or "put it together into a report". Also when another task produces tabular data worth analyzing. Do NOT use for one-off single-number lookups the researcher can answer.
---

# Data science — acquire, analyze, present

Stack (shared venv, on PATH): pandas, numpy, scipy, matplotlib,
requests + BeautifulSoup/lxml (scraping), pandas.read_html (tables),
plus the office skill for xlsx/pdf deliverables and the `data` agent for
delegating heavy pulls. Read the detail file for the phase you're in:

| Phase | File |
|---|---|
| Getting data: scraping, APIs, files | `scraping.md` |
| Cleaning, reshaping, statistics | `analysis.md` |
| Charts, tables, assembled reports | `present.md` |

## The pipeline discipline

1. **Acquire once, save raw**: every pull lands in a raw file (csv/json)
   before any transformation — re-analysis must never re-fetch. Record the
   fetch timestamp and source URL alongside it.
2. **Wrangle in a script**, never by eyeballing: the path from raw file to
   every reported number must be rerunnable. Validate on ingest — row counts,
   nulls, duplicates, dtypes, units, timezones — and print the validation.
3. **Analyze with statistical care**: denominators with every rate, medians
   on skewed data, n stated, confounders named. A surprising number means
   check the pipeline before believing the world.
4. **Present as a deliverable**: chart PNGs + a tight write-up, or an xlsx/pdf
   via the office skill when the user wants a file. Every figure captioned
   with source + date + n. "Put together" means one artifact someone else
   can read cold — not a directory of fragments.

## Honesty rules

- Numbers come from the data actually loaded this session — never from
  model memory of what the data "should" say.
- State what was dropped (rows filtered, nulls, outliers) and why; silent
  cleaning is fabrication's polite cousin.
- Correlation language stays correlational unless the design supports more.

## Learned the hard way
_Appended automatically as Serge learns; gated by this skill's own tests._
- Use `polars` instead of `pandas` for all data wrangling and analysis tasks to leverage better performance and memory efficiency, as the user explicitly prefers the polars ecosystem.
