# Acquiring data — scraping, APIs, files

## Order of preference (always)

1. **An official API or export** — look for it FIRST: `/api/` endpoints in
   the page's network calls, a "download CSV" link, an open-data portal, a
   documented API. Ten minutes finding the JSON beats an hour parsing HTML
   that breaks next week.
2. **The page's own data payload** — modern sites ship data as JSON inside
   the HTML: `<script id="__NEXT_DATA__">`, `window.__INITIAL_STATE__`,
   inline `application/ld+json`. Fetch once, regex/parse the blob, done.
3. **HTML scraping** — requests + BeautifulSoup/lxml, patterns below.
4. **JS-rendered pages** — no headless browser installed ($0 line): fetch
   through Jina Reader (`https://r.jina.ai/<full-url>`, keyless) which
   renders and returns clean text/markdown; or find the underlying API
   (option 2 — the JS got the data from somewhere).

## Scraping patterns

```python
import requests
from bs4 import BeautifulSoup
UA = {"User-Agent": "Mozilla/5.0 (research; contact you@example.com)"}
r = requests.get(url, headers=UA, timeout=30)
r.raise_for_status()
soup = BeautifulSoup(r.text, "lxml")
```

- **Tables**: `pandas.read_html(io.StringIO(r.text))` first — it eats most
  `<table>`s directly into DataFrames. Bs4 only for non-table structures.
- **Selectors**: prefer stable hooks (ids, data-* attributes, aria labels)
  over brittle class soup (`css-1x2y3z` changes weekly). `soup.select()`
  with CSS selectors reads better than nested find chains.
- **Pagination**: find the pattern (page=N, offset, cursor in the response);
  loop with `time.sleep(1)`-ish politeness and a hard page cap; log progress
  every page; save incrementally so a crash keeps partial data.
- **Encoding**: trust `r.content` + explicit decode over `r.text` when
  accents look wrong; `utf-8-sig` for Excel-born CSVs.
- **Defensive parsing**: every extracted field via a helper that returns
  None on missing — real pages are ragged; one absent node must not kill
  the run. Count and report None rates at the end.

## Etiquette & judgment

- Identify yourself in the UA; keep request rates polite (~1/s), back off on
  429/503. Respect robots.txt for crawling (fetching a handful of public
  pages for analysis is fine judgment territory; mass-harvesting against a
  site's wishes isn't).
- Auth-walled, personal, or paid data: don't scrape around it — say so and
  use what's legitimately accessible.
- Every saved dataset gets: source URL, fetch timestamp, and the script that
  produced it, so the number's provenance survives the session.

## Files & formats

pandas reads csv/json/parquet/xlsx (office venv has openpyxl) directly;
`json_normalize` flattens nested API JSON; for logs, read lines → regex to
columns → DataFrame; for SQL, `pd.read_sql` needs a driver — sqlite3 is
stdlib and always available.
