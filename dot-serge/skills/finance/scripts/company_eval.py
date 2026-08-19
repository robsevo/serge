#!/usr/bin/env python3
"""Terminal-style company tear sheet: EDGAR fundamentals + stooq price stats.

Usage: python3 company_eval.py TICKER [--json]
Every number is fetched live and tagged with source + as-of date. Missing = "—",
never estimated. US filers only (EDGAR); price via stooq EOD.
"""
import json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from edgar_facts import get_fundamentals
from quote_hist import get_stats

DASH = "—"


def hum(v, money=True):
    if v is None:
        return DASH
    a = abs(v)
    for div, suf in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if a >= div:
            s = f"{v / div:,.1f}{suf}"
            break
    else:
        s = f"{v:,.2f}"
    return f"({s.lstrip('-')})" if v < 0 else s


def pct(v, signed=True):
    if v is None:
        return DASH
    s = f"{v * 100:+.1f}%" if signed else f"{v * 100:.1f}%"
    return s


def ratio(v):
    return DASH if v is None else f"{v:,.2f}"


def div(a, b):
    try:
        return a / b if a is not None and b else None
    except ZeroDivisionError:
        return None


def build(ticker):
    fund = get_fundamentals(ticker)
    px = None
    try:
        px = get_stats(ticker)
    except SystemExit as e:
        px = {"error": str(e)}
    fys = fund["fiscal_years"]
    latest = fys[0] if fys else {}
    shares = (fund.get("shares_outstanding") or {}).get("val")
    price = px.get("close") if px and "error" not in px else None
    mcap = price * shares if price and shares else None
    ev = None
    if mcap is not None:
        ev = mcap + (latest.get("total_debt") or 0) - (latest.get("cash") or 0)
    ebitda = None
    if latest.get("operating_income") is not None and latest.get("dep_amort") is not None:
        ebitda = latest["operating_income"] + latest["dep_amort"]

    d = {"fund": fund, "px": px, "derived": {
        "mkt_cap": mcap, "ev": ev, "ebitda": ebitda,
        "pe": div(price, latest.get("eps_diluted")),
        "ev_ebitda": div(ev, ebitda),
        "ps": div(mcap, latest.get("revenue")),
        "roe": div(latest.get("net_income"), latest.get("equity")),
        "de": div(latest.get("total_debt"), latest.get("equity")),
        "net_margin": div(latest.get("net_income"), latest.get("revenue")),
        "gross_margin": div(latest.get("gross_profit"), latest.get("revenue")),
        "op_margin": div(latest.get("operating_income"), latest.get("revenue")),
        "fcf_yield": div(latest.get("fcf"), mcap),
        "fcf_ni": div(latest.get("fcf"), latest.get("net_income")),
    }}

    flags = []
    yoy = [div(a.get("revenue"), b.get("revenue")) and a["revenue"] / b["revenue"] - 1
           for a, b in zip(fys, fys[1:])]
    if d["derived"]["fcf_ni"] is not None and d["derived"]["fcf_ni"] < 0.8:
        flags.append(f"FCF/NI {d['derived']['fcf_ni']:.2f} <0.8 — accrual-heavy earnings, check working capital")
    if len(yoy) >= 2 and yoy[0] is not None and yoy[1] is not None and yoy[0] < yoy[1] - 0.03:
        flags.append(f"revenue growth decelerating ({pct(yoy[1])} -> {pct(yoy[0])})")
    if d["derived"]["de"] is not None and d["derived"]["de"] > 2:
        flags.append(f"debt/equity {d['derived']['de']:.2f} — leverage above 2x")
    sh = [f.get("shares_diluted") for f in fys]
    if len(sh) >= 2 and sh[0] and sh[1] and sh[0] > sh[1] * 1.02:
        flags.append(f"diluted share count +{(sh[0] / sh[1] - 1) * 100:.1f}% yoy — dilution creep")
    margins = [div(f.get("net_income"), f.get("revenue")) for f in fys]
    if len(margins) >= 3 and all(m is not None for m in margins[:3]) and margins[0] < margins[1] < margins[2]:
        flags.append("net margin falling two consecutive years")
    d["flags"] = flags
    d["yoy"] = yoy
    return d


def render(d):
    f, p, dv = d["fund"], d["px"], d["derived"]
    fys = f["fiscal_years"][:3]
    W = 78
    L = []
    L.append("═" * W)
    L.append(f" {f['ticker']} — {f['company'].upper():<50} SEC CIK {f['cik']}")
    L.append("═" * W)
    if "error" in p:
        L.append(f" PX  unavailable ({p['error']})")
    else:
        L.append(f" PX  {p['close']:,.2f} USD  EOD {p['asof']} [stooq]"
                 f"      52W {p['lo_52w']:,.2f} {DASH} {p['hi_52w']:,.2f}  ({pct(p['off_high'])} off hi)")
        L.append(f" 1D {pct(p['ret_1d'])}   1M {pct(p['ret_1m'])}   YTD {pct(p['ret_ytd'])}"
                 f"   1Y {pct(p['ret_1y'])}    VOL(ann) {pct(p['vol_ann'], signed=False)}"
                 f"   BETA {ratio(p.get('beta_1y_spx'))}")
        trend = lambda s: "" if p.get(s) is None else (" ▲" if p["close"] > p[s] else " ▼")
        L.append(f" SMA50 {ratio(p.get('sma50'))}{trend('sma50')}   SMA200 {ratio(p.get('sma200'))}{trend('sma200')}"
                 f"   RSI14 {p['rsi14']:.0f}   MAXDD(1Y) {pct(p['max_dd_1y'])}")
    L.append("─" * W)
    hdr = " FUNDAMENTALS [SEC EDGAR 10-K]".ljust(38) + "".join(
        (fy.get("fy_label") or fy["fy_end"][:4]).rjust(13) for fy in fys)
    L.append(hdr)
    L.append("   fiscal year end".ljust(38) + "".join(fy["fy_end"].rjust(13) for fy in fys))

    def row(label, key, fmt=hum):
        L.append(f"   {label}".ljust(38) + "".join(fmt(fy.get(key)).rjust(13) for fy in fys))

    row("Revenue", "revenue")
    L.append("     yoy".ljust(38) + "".join(
        (pct(d["yoy"][i]) if i < len(d["yoy"]) else DASH).rjust(13) for i in range(len(fys))))
    row("Gross profit", "gross_profit")
    row("Operating income", "operating_income")
    row("Net income", "net_income")
    row("Diluted EPS", "eps_diluted", lambda v: DASH if v is None else f"{v:,.2f}")
    row("Op cash flow", "ocf")
    row("CapEx", "capex")
    row("Free cash flow", "fcf")
    row("Cash", "cash")
    row("Total debt", "total_debt")
    row("Equity", "equity")
    L.append("─" * W)
    sh = f.get("shares_outstanding") or {}
    L.append(f" MKT CAP {hum(dv['mkt_cap'])}  (shares {hum(sh.get('val'), money=False)}"
             f" asof {sh.get('asof', DASH)} [EDGAR dei] x stooq px)   EV {hum(dv['ev'])}")
    L.append(f" RATIOS (latest FY x current px)")
    L.append(f"   P/E {ratio(dv['pe'])}    EV/EBITDA {ratio(dv['ev_ebitda'])}    P/S {ratio(dv['ps'])}"
             f"    FCF yield {pct(dv['fcf_yield'], signed=False)}")
    L.append(f"   Gross mgn {pct(dv['gross_margin'], signed=False)}   Op mgn {pct(dv['op_margin'], signed=False)}"
             f"   Net mgn {pct(dv['net_margin'], signed=False)}   ROE {pct(dv['roe'], signed=False)}"
             f"   D/E {ratio(dv['de'])}")
    L.append(" FLAGS")
    if d["flags"]:
        for fl in d["flags"]:
            L.append(f"   ⚠ {fl}")
    else:
        L.append("   none tripped (see fundamentals.md checklist for the manual passes)")
    filed = fys[0].get("filed", DASH) if fys else DASH
    L.append("─" * W)
    L.append(f" SRC fundamentals: SEC EDGAR companyfacts (latest 10-K filed {filed})"
             f" · price: stooq EOD · all ratios computed")
    L.append("═" * W)
    return "\n".join(L)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    d = build(args[0])
    if "--json" in args:
        print(json.dumps(d, indent=2, default=str))
    else:
        print(render(d))
