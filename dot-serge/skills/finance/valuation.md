# Valuation — multiples, comps, DCF

## Choosing the lens

| Situation | Primary multiple |
|---|---|
| Profitable, stable | P/E (use diluted EPS), EV/EBIT |
| Capital-intensive / different D&A | EV/EBITDA |
| Pre-profit growth | EV/Sales + gross margin + growth (Rule of 40 for SaaS: growth% + FCF margin% ≥ 40) |
| Banks / insurers | P/B and ROE together (P/B ≈ justified by ROE vs cost of equity) |
| Cash cows | FCF yield (FCF/market cap — >5-6% is real money; compare to bond yields) |

EV = market cap + total debt − cash. COMPUTE it — never quote someone's EV.
Trailing vs forward: label which; forward numbers are estimates, source them.

## Comps (the honest way)

1. Pick 4-8 TRUE peers — same business model and capital intensity, not just
   same sector label ("researcher" agent finds them; verify each does what
   you think).
2. Build the table yourself from EDGAR + prices: EV/EBITDA, P/E, EV/S, growth,
   margin, ROIC for each. Same fiscal basis across the row.
3. The spread IS the finding: if the target trades below peers, the question
   is "what does the market think is wrong" — answer it (growth? margin?
   balance sheet? governance?) before calling it cheap.

## DCF (an assumptions amplifier — present it as one)

FCFF route: project revenue growth → operating margin → NOPAT (tax ~21-25%)
→ subtract capex & working-capital needs → FCFF for 5 years.

- **WACC** via CAPM: risk-free (10Y treasury, fetch it) + beta (quote_hist.py
  computes vs S&P) × equity premium (~4.5-5.5%); blend with after-tax debt
  cost by capital weights. STATE every input.
- **Terminal value**: Gordon with g = 2-3% MAX (nominal GDP-ish; anything
  higher assumes the company outgrows the economy forever), or an exit
  multiple cross-check. TV is usually 60-75% of the total — say so; the DCF
  mostly prices the terminal assumption.
- **Sensitivity grid — mandatory**: value across WACC ±1pt × g ±0.5pt (or
  margin ±2pts). Present the GRID and the implied-vs-market gap, never a
  lone intrinsic value. If the current price sits inside the grid's plausible
  band, the honest verdict is "fairly priced under these assumptions."
- Reverse DCF is often sharper: what growth/margin does TODAY'S price imply?
  Then judge whether that's achievable — turns speculation into a concrete
  question.

## Margin of safety framing

A buy case needs the valuation to work under conservative inputs, an
identifiable reason the market misprices it, and a falsifier ("wrong if X").
State all three or say which is missing. Direct recommendations are fine —
grounded, with the conditions under which they break.
