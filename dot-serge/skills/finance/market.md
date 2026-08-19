# Market data — prices, risk, technicals

## Getting prices

- **stooq** (script default): `https://stooq.com/q/d/l/?s=aapl.us&i=d` → CSV
  OHLCV, full daily history, EOD. US tickers take `.us`; indices: `^spx`
  (S&P 500), `^ndq` (Nasdaq). No key, no auth. GOTCHA (2026-07-17): stooq
  fingerprints the TLS client — python requests gets 404, curl gets the CSV;
  fetch via curl subprocess (quote_hist.py already does).
- **yfinance** (venv): `yf.Ticker("AAPL")` — `.history(period=...)`,
  `.info` (market cap, float, delayed quote), `.calendar` (earnings date),
  options chains, non-US listings. Treat as convenience: ~15 min delayed,
  fields appear/vanish with Yahoo's whims — cross-check anything load-bearing.
- NEVER present either as real-time. Tag prices "EOD yyyy-mm-dd [stooq]" or
  "delayed [yahoo]".

## Stats that belong in an eval (quote_hist.py computes all)

- Returns: 1D/1M/YTD/1Y; 52-week high/low and % off high (drawdown from peak
  = the market's current verdict).
- Volatility: stdev of daily log returns × √252, annualized. 15-25% = typical
  large cap; >40% = the market prices real uncertainty.
- Max drawdown (1Y): worst peak-to-trough — the "can you hold it" number.
- Beta vs S&P (1Y daily): <0.8 defensive, ~1 market, >1.3 amplified. Feeds
  the CAPM in valuation.md.
- SMA50 vs SMA200: price above both + 50>200 = uptrend regime; the golden/
  death cross is regime change, not prophecy.
- RSI(14): >70 stretched, <30 washed out — context flag, not a signal to act
  on alone.

## Discipline

- Technicals describe positioning and regime; fundamentals value the
  business. In a company eval, price stats explain WHERE you are in the
  story (momentum, sentiment) — the thesis still comes from the numbers and
  the filings.
- Past returns are not evidence about future returns; a backtest without
  costs/slippage/out-of-sample is marketing. If asked to backtest, say those
  limits and build it honestly (pandas is in the venv).
- Portfolio math quickies: position return contributions, correlation matrix
  of daily returns (pandas `.corr()`), simple rebalance drift — all fine
  locally; anything needing live intraday execution data, say it's out of
  reach on the free stack.
