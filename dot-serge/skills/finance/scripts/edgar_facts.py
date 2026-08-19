#!/usr/bin/env python3
"""SEC EDGAR fundamentals for a US-listed ticker. Official data, no API key.

Usage: python3 edgar_facts.py TICKER [--years N]
Prints JSON: last N fiscal years of key line items + derived ratios.
Importable: get_fundamentals(ticker) -> dict.
"""
import json, socket, sys
import requests

# This box's IPv6 is half-configured: getaddrinfo returns AAAA first and every
# connect burns ~15s timing out before falling back to IPv4 (measured
# 2026-07-18: 16s vs curl's 0.3s happy-eyeballs). Force IPv4 for urllib3.
import urllib3.util.connection as _u3conn
_u3conn.allowed_gai_family = lambda: socket.AF_INET

UA = {"User-Agent": "serge-agent research you@example.com"}
TIMEOUT = 30

# concept -> ordered fallback chain of us-gaap tags (companies differ)
TAG_CHAINS = {
    "revenue": ["RevenueFromContractWithCustomerExcludingAssessedTax", "Revenues", "SalesRevenueNet"],
    "cost_of_revenue": ["CostOfRevenue", "CostOfGoodsAndServicesSold", "CostOfGoodsSold"],
    "gross_profit": ["GrossProfit"],
    "operating_income": ["OperatingIncomeLoss"],
    "net_income": ["NetIncomeLoss"],
    "eps_diluted": ["EarningsPerShareDiluted"],
    "assets": ["Assets"],
    "liabilities": ["Liabilities"],
    "equity": ["StockholdersEquity",
               "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"],
    "cash": ["CashAndCashEquivalentsAtCarryingValue"],
    "lt_debt": ["LongTermDebtNoncurrent", "LongTermDebt"],
    "st_debt": ["LongTermDebtCurrent"],
    "ocf": ["NetCashProvidedByUsedInOperatingActivities"],
    "capex": ["PaymentsToAcquirePropertyPlantAndEquipment",
              "PaymentsToAcquireProductiveAssets"],
    "dep_amort": ["DepreciationDepletionAndAmortization", "DepreciationAndAmortization"],
    "shares_diluted": ["WeightedAverageNumberOfDilutedSharesOutstanding"],
}


def _get(url):
    r = requests.get(url, headers=UA, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def ticker_to_cik(ticker):
    data = _get("https://www.sec.gov/files/company_tickers.json")
    t = ticker.upper()
    for row in data.values():
        if row["ticker"] == t:
            return f"{row['cik_str']:010d}", row["title"]
    raise SystemExit(f"ticker {t} not found in SEC registry (US filers only)")


def annual_series(facts, tag, unit_pref=("USD", "USD/shares", "shares")):
    node = facts.get("us-gaap", {}).get(tag)
    if not node:
        return {}
    units = node.get("units", {})
    entries = None
    for u in unit_pref:
        if u in units:
            entries = units[u]
            break
    if entries is None:
        entries = next(iter(units.values()), [])
    out = {}
    for e in entries:
        # NB: don't skip frame-carrying entries — sometimes the ONLY entry for
        # a fiscal year has a frame (Apple FY2025); dedupe-by-end handles dupes.
        if e.get("form") != "10-K":
            continue
        end = e.get("end", "")
        # keep annual-duration or instant (balance sheet) facts only
        if e.get("start"):
            try:
                span = (int(end[:4]) - int(e["start"][:4])) * 12 + int(end[5:7]) - int(e["start"][5:7])
            except (ValueError, IndexError):
                continue
            if not 10 <= span <= 14:
                continue
        prev = out.get(end)
        if prev is None or e.get("filed", "") > prev.get("filed", ""):
            out[end] = e
    return out


def pick(facts, concept):
    # MERGE the chain per fiscal year rather than returning the first tag with
    # any data: companies switch tags across filings (NVDA's revenue moved
    # between Revenues and RevenueFromContract…), so first-tag-wins silently
    # truncated the series to the OLD years. Earlier tags in the chain win
    # only on a per-year conflict.
    merged = {}
    for tag in TAG_CHAINS[concept]:
        for end, e in annual_series(facts, tag).items():
            if end not in merged:
                merged[end] = e
    return merged


def get_fundamentals(ticker, years=4):
    cik, title = ticker_to_cik(ticker)
    facts = _get(f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json")["facts"]
    series = {c: pick(facts, c) for c in TAG_CHAINS}
    # fiscal-year ends = the revenue series' ends (fall back to net income's)
    ends = sorted(series["revenue"] or series["net_income"], reverse=True)[:years]
    fys = []
    for end in ends:
        row = {"fy_end": end}
        for c, s in series.items():
            e = s.get(end)
            row[c] = e["val"] if e else None
            if c == "revenue" and e:
                row["filed"] = e.get("filed")
                # XBRL `fy` is the FILING's fiscal year (lies on comparative
                # facts) — label from the period end year instead.
                row["fy_label"] = f"FY{end[:4]}"
        if row.get("gross_profit") is None and row.get("revenue") and row.get("cost_of_revenue"):
            row["gross_profit"] = row["revenue"] - row["cost_of_revenue"]
        debt = sum(v for v in (row.get("lt_debt"), row.get("st_debt")) if v)
        row["total_debt"] = debt or None
        if row.get("ocf") is not None and row.get("capex") is not None:
            row["fcf"] = row["ocf"] - row["capex"]
        fys.append(row)
    shares_now = None
    dei = facts.get("dei", {}).get("EntityCommonStockSharesOutstanding", {}).get("units", {}).get("shares", [])
    if dei:
        latest = max(dei, key=lambda e: e.get("end", ""))
        shares_now = {"val": latest["val"], "asof": latest.get("end")}
    return {"ticker": ticker.upper(), "company": title, "cik": cik,
            "source": "SEC EDGAR companyfacts", "shares_outstanding": shares_now,
            "fiscal_years": fys}


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    n = int(args[args.index("--years") + 1]) if "--years" in args else 4
    print(json.dumps(get_fundamentals(args[0], n), indent=2))
