---
name: finance
description: Company evaluation, stock analysis, and crypto/memecoin due diligence, terminal-style — SEC EDGAR fundamentals, price/market stats, valuation (DCF/comps), on-chain token checks (bundling, LP, supply), dense sourced tear sheets. Free data only, every number dated and sourced.
whenToUse: Use whenever the user asks about a stock, company, token, or investment analysis — "evaluate/analyze [company]", a ticker symbol, fundamentals, earnings, valuation, P/E or any ratio, DCF, comparing companies, price history, volatility, portfolio questions, "is X a good buy" — AND for crypto - any token/mint address, memecoins, pump.fun launches, "is it bundled/rugged", liquidity pools, holder concentration, honeypot checks. Also for reading 10-K/10-Q filings. Do NOT use for personal budgeting or tax filing mechanics.
---

# Finance — company evals, terminal style

## Data stack ($0, no API keys)

| Source | What | Trust |
|---|---|---|
| **SEC EDGAR** (`data.sec.gov`) | Official XBRL fundamentals, all US filers, filings full text | The primary source — it's what the terminals ingest. Needs a User-Agent with contact info; scripts set it. ~10 req/s limit. |
| **stooq.com** | EOD price history CSV, no key (`TICKER.us`) | Reliable; end-of-day only. |
| **yfinance** (venv) | Convenience: quotes (~15 min delayed), analyst data, options, non-US listings | Scrapes Yahoo — can silently break or change; treat every field as unverified until cross-checked, prefer EDGAR/stooq for anything load-bearing. |
| **researcher agent** | News, catalysts, management changes, sector context | For the narrative layer the numbers can't give. |

House scripts in this skill's `scripts/` dir (plain `python3`, print JSON or text):

- `company_eval.py TICKER` — THE tear sheet: price block + FY fundamentals +
  ratios + red-flag checks, every number tagged with source and as-of date.
  Start every company evaluation by running this.
- `edgar_facts.py TICKER` — raw multi-year fundamentals JSON from EDGAR
  (handles the XBRL tag-name mess; see fundamentals.md).
- `quote_hist.py TICKER` — price stats JSON: returns, 52w range, volatility,
  drawdown, SMA50/200, RSI, beta vs S&P.
- `token_eval.py MINT_OR_QUERY` — crypto/memecoin tear sheet: pool
  composition, LP lock, holder concentration, insider/bundle clustering,
  authorities, honeypot/tax checks (Solana incl. pump.fun; EVM via 0x addr).

## Route by task

| Ask | Do |
|---|---|
| "Evaluate/analyze $TICKER", "how's [company] doing" | `company_eval.py`, then interpret per fundamentals.md; add researcher pass for news/catalysts |
| "Is it cheap/expensive", price targets, DCF, comps | valuation.md — build the comps table / DCF WITH sensitivity grid |
| Ratio meaning, margins, balance-sheet health, red flags | fundamentals.md |
| Price action, volatility, beta, drawdowns, momentum | `quote_hist.py` + market.md |
| "Read the 10-K", segment detail, risk factors | EDGAR filing full text (fundamentals.md has URLs) — fetch and read the actual sections |
| Any token/memecoin: "is it safe/bundled", pump.fun, LP, supply | `token_eval.py`, interpret per crypto.md — flags are one-way evidence |
| Deep dive / "research [company]" | full parallel panel: this skill's numbers + researcher agents on news/competitors/industry (the /research pattern) |

## Presentation: terminal style

Dense, aligned, scannable — the Bloomberg register:

- Lead with the tear sheet block (monospace), then interpretation in prose.
- Numbers humanized (416.2B, 46.9%, not 416161000000), negatives in parens
  (Bloomberg convention), deltas signed (+6.4% yoy).
- EVERY number carries provenance: source tag + as-of date. Fundamentals are
  as-of the fiscal period END and note the FILING date; prices are EOD or
  delayed — say which. Never present stale as current.
- Missing data renders as `—`, never an estimate passed off as data. Estimates
  are allowed only labeled as such with their assumptions.
- Close with a clear, direct read: what the numbers say, what would change the
  thesis, what to check next. Rigor plus a real opinion — not hedging mush.

## Honesty rules (non-negotiable)

- Every figure in an eval traces to a fetch made THIS session by script or
  tool — quoting fundamentals or prices from model memory is fabrication.
- A DCF output is an assumptions amplifier: always show the sensitivity grid
  and the assumptions, never a lone point value.
- Analysis can be sharp and opinionated (constitution: trust the user); data
  can never be invented, and uncertainty is stated, not hidden.
