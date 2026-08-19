# Fundamentals — EDGAR, ratios, red flags

## EDGAR mechanics

- Ticker → CIK: `https://www.sec.gov/files/company_tickers.json` (all tickers,
  zero-pad CIK to 10 digits).
- All fundamentals: `https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json`
  — every XBRL fact the company ever filed, by tag → unit → entries with
  `fy`, `fp` (FY/Q1..Q3), `form` (10-K/10-Q), `end` (period end), `filed`, `val`.
- Filing index & full text: `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=...&type=10-K`
  → the 10-K sections that matter beyond numbers: Item 1A (risk factors),
  Item 7 (MD&A — management's own explanation of the numbers), segment
  footnotes (where the "one company" is really three businesses).
- Etiquette: User-Agent must identify you with contact info; ≤10 req/s.

**The tag mess** (why `edgar_facts.py` exists): companies file the same
concept under different us-gaap tags. Use fallback chains, first hit wins:

| Concept | Tag chain |
|---|---|
| Revenue | RevenueFromContractWithCustomerExcludingAssessedTax → Revenues → SalesRevenueNet |
| Net income | NetIncomeLoss |
| Gross profit | GrossProfit (else Revenue − CostOfRevenue) |
| Operating income | OperatingIncomeLoss |
| Operating cash flow | NetCashProvidedByUsedInOperatingActivities |
| CapEx | PaymentsToAcquirePropertyPlantAndEquipment |
| Total assets / liabilities | Assets / Liabilities |
| Equity | StockholdersEquity → ...IncludingPortionAttributableToNoncontrollingInterest |
| Cash | CashAndCashEquivalentsAtCarryingValue |
| Debt | LongTermDebtNoncurrent + LongTermDebtCurrent → LongTermDebt |
| Diluted EPS | EarningsPerShareDiluted |
| D&A | DepreciationDepletionAndAmortization → DepreciationAndAmortization |
| Shares out | dei:EntityCommonStockSharesOutstanding (latest) |

Annual series: filter `form=10-K`, dedupe by fiscal `end` keeping the latest
`filed` (restatements supersede). FY labels ≠ calendar years (Apple's FY ends
September). TTM requires stitching 10-Qs — do it only when asked; label
"FY2025 annual" honestly otherwise.

## Ratios: formula + how to read it

- **Growth**: revenue yoy; 3-5yr CAGR. Deceleration matters more than level.
- **Margins**: gross (pricing power/moat), operating (cost discipline), net.
  Compare WITHIN sector only — software 70-80% gross is normal, grocery ~25%.
  Direction over 3+ years beats any single value.
- **ROE** = NI/equity. >15% sustained = quality, but check it isn't just
  leverage: **ROIC** ≈ NOPAT/(equity+debt−cash) is the honest version —
  value is created when ROIC > WACC (~8-10% typical).
- **Liquidity**: current ratio (>1.5 comfortable, <1 tight); quick ratio for
  inventory-heavy names.
- **Leverage**: debt/equity (sector-dependent — utilities run high, software
  low); net debt/EBITDA (>3x gets attention); interest coverage
  (EBIT/interest, <3x fragile).
- **Cash conversion**: FCF = OCF − capex. FCF/NI near or above 1 = earnings
  are cash; persistently <0.8 = accrual-heavy earnings, dig into working
  capital.
- **Per share**: diluted EPS; watch share COUNT over years — buybacks
  (shrinking) vs SBC dilution (creeping up 2-4%/yr in tech).

## Red flags (the accounting smell test)

- CFO persistently below net income → earnings on paper, not cash.
- Receivables or inventory growing faster than revenue → channel stuffing /
  demand rolling over.
- Serial "one-time" restructuring charges, every year → they're operating costs.
- Goodwill a huge share of assets → acquisition roll-up; impairment risk.
- Auditor changes, delayed filings, CFO departures — process smoke.
- Segment disclosure shrinking or metrics redefined (the "adjusted" creep).

Flag what the data shows, check the MD&A for management's story, and say
which explanation you find credible — that's the analysis.
