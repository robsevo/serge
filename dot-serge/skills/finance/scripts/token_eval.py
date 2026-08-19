#!/usr/bin/env python3
"""Memecoin/token due-diligence tear sheet. Free sources, no keys.

Usage: python3 token_eval.py MINT_OR_0xADDR_OR_QUERY [--json]
Solana (incl. pump.fun): DexScreener + RugCheck + Solana RPC.
EVM (0x...): DexScreener + GoPlus token_security.
Every section is best-effort per source — an unreachable source renders as
"unavailable", never invented. Flags are one-way evidence: tripped = bad;
clean = NOT proof of safe.
"""
import json, re, sys
import requests

TIMEOUT = 25
UA = {"User-Agent": "serge-agent research you@example.com"}
SOL_RPC = "https://api.mainnet-beta.solana.com"
GOPLUS_CHAINS = {"ethereum": "1", "bsc": "56", "base": "8453", "arbitrum": "42161"}
DASH = "—"


def get(url):
    r = requests.get(url, headers=UA, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


def hum(v):
    if v in (None, ""):
        return DASH
    v = float(v)
    for div_, suf in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")):
        if abs(v) >= div_:
            return f"{v / div_:,.2f}{suf}"
    return f"{v:,.4f}" if abs(v) < 1 else f"{v:,.2f}"


def resolve(query):
    """Return (chain, address, best_pair) via dexscreener."""
    if re.fullmatch(r"0x[0-9a-fA-F]{40}", query) or re.fullmatch(r"[1-9A-HJ-NP-Za-km-z]{32,44}", query):
        data = get(f"https://api.dexscreener.com/latest/dex/tokens/{query}")
        pairs = data.get("pairs") or []
    else:
        data = get(f"https://api.dexscreener.com/latest/dex/search?q={query}")
        pairs = [p for p in (data.get("pairs") or [])]
    if not pairs:
        raise SystemExit(f"dexscreener: no pairs found for {query!r}")
    pairs.sort(key=lambda p: (p.get("liquidity") or {}).get("usd") or 0, reverse=True)
    best = pairs[0]
    return best["chainId"], best["baseToken"]["address"], best, pairs


def sol_rpc(method, params):
    r = requests.post(SOL_RPC, json={"jsonrpc": "2.0", "id": 1, "method": method, "params": params},
                      timeout=TIMEOUT)
    r.raise_for_status()
    return r.json().get("result")


def solana_chain_data(mint):
    out = {}
    try:
        sup = sol_rpc("getTokenSupply", [mint])
        out["supply"] = float(sup["value"]["uiAmount"])
        out["decimals"] = sup["value"]["decimals"]
    except Exception as e:
        out["supply_error"] = f"{type(e).__name__}"
    try:
        largest = sol_rpc("getTokenLargestAccounts", [mint])["value"]
        out["top20_accounts"] = [{"address": a["address"], "ui": float(a["uiAmount"] or 0)} for a in largest]
    except Exception as e:
        out["largest_error"] = f"{type(e).__name__}"
    return out


def rugcheck(mint):
    try:
        return get(f"https://api.rugcheck.xyz/v1/tokens/{mint}/report")
    except Exception as e:
        return {"error": f"rugcheck unavailable: {type(e).__name__}"}


def goplus(chain, addr):
    cid = GOPLUS_CHAINS.get(chain)
    if not cid:
        return {"error": f"goplus: chain {chain} not mapped"}
    try:
        res = get(f"https://api.gopluslabs.io/api/v1/token_security/{cid}?contract_addresses={addr}")
        return res.get("result", {}).get(addr.lower(), {}) or {"error": "goplus: empty result"}
    except Exception as e:
        return {"error": f"goplus unavailable: {type(e).__name__}"}


def build(query):
    chain, addr, best, pairs = resolve(query)
    d = {"chain": chain, "address": addr, "pair": best,
         "n_pairs": len(pairs),
         "pumpfun": any(p.get("dexId", "").startswith("pump") for p in pairs)}
    if chain == "solana":
        d["onchain"] = solana_chain_data(addr)
        d["rugcheck"] = rugcheck(addr)
    else:
        d["goplus"] = goplus(chain, addr)

    flags, notes = [], []
    liq = (best.get("liquidity") or {}).get("usd")
    fdv = best.get("fdv")
    tx = (best.get("txns") or {}).get("h24") or {}
    buys, sells = tx.get("buys"), tx.get("sells")
    if liq is not None and liq < 10_000:
        flags.append(f"liquidity ${hum(liq)} — exit door is tiny")
    if liq and fdv and fdv > 0 and liq / fdv < 0.02:
        flags.append(f"liq/FDV {liq / fdv:.1%} — mcap is theoretical vs the real pool")
    if buys and sells and sells > 0 and buys / max(sells, 1) > 4:
        flags.append(f"24h buys/sells {buys}/{sells} — one-sided flow, possible push")

    rc = d.get("rugcheck", {})
    if rc and "error" not in rc:
        tok = rc.get("token") or {}
        if tok.get("mintAuthority"):
            flags.append("MINT AUTHORITY ACTIVE — supply can be inflated at will")
        if tok.get("freezeAuthority"):
            flags.append("FREEZE AUTHORITY ACTIVE — your wallet can be frozen")
        th = rc.get("topHolders") or []
        ins_pct = sum(h.get("pct", 0) for h in th if h.get("insider"))
        top10 = sum(h.get("pct", 0) for h in th[:10])
        d["holders_summary"] = {"top10_pct": top10, "insider_pct_top": ins_pct,
                                "total_holders": rc.get("totalHolders"),
                                "insider_networks": len(rc.get("insiderNetworks") or [])}
        if ins_pct > 10:
            flags.append(f"insider cluster holds {ins_pct:.1f}% (rugcheck graph) — BUNDLED")
        elif rc.get("insiderNetworks"):
            notes.append(f"{len(rc['insiderNetworks'])} insider network(s) detected below flag threshold")
        if top10 > 30:
            flags.append(f"top-10 holders {top10:.1f}% of supply — concentrated")
        markets = rc.get("markets") or []
        lp_locked = max((((m.get("lp") or {}).get("lpLockedPct")) or 0) for m in markets) if markets else None
        d["lp_locked_pct"] = lp_locked
        if lp_locked is not None and lp_locked < 50 and not d["pumpfun"]:
            flags.append(f"LP locked/burned only {lp_locked:.0f}% — pullable liquidity")
        for r_ in (rc.get("risks") or []):
            if r_.get("level") in ("danger", "warn"):
                flags.append(f"[rugcheck {r_.get('level')}] {r_.get('name')}: {r_.get('description', '')[:70]}")

    gp = d.get("goplus", {})
    if gp and "error" not in gp:
        if gp.get("is_honeypot") == "1":
            flags.append("HONEYPOT (goplus) — you can buy, you cannot sell")
        for k, msg in (("is_mintable", "mintable"), ("owner_change_balance", "owner can edit balances"),
                       ("transfer_pausable", "transfers pausable"), ("cannot_sell_all", "cannot sell all")):
            if gp.get(k) == "1":
                flags.append(f"{msg} (goplus)")
        bt, st = gp.get("buy_tax"), gp.get("sell_tax")
        if st and float(st or 0) > 0.10:
            flags.append(f"sell tax {float(st):.0%}")
        d["taxes"] = {"buy": bt, "sell": st}
    d["flags"] = flags
    d["notes"] = notes
    return d


def render(d):
    p = d["pair"]
    base, quote = p["baseToken"], p["quoteToken"]
    liq = p.get("liquidity") or {}
    tx = (p.get("txns") or {}).get("h24") or {}
    ch = p.get("priceChange") or {}
    W = 78
    L = ["═" * W,
         f" {base.get('symbol', '?')} — {base.get('name', '?')[:40]}   [{d['chain']} · {p.get('dexId')}"
         f"{' · pump.fun lineage' if d['pumpfun'] else ''}]",
         f" {d['address']}",
         "═" * W,
         f" PX ${p.get('priceUsd', DASH)}   1h {ch.get('h1', DASH)}%  6h {ch.get('h6', DASH)}%  24h {ch.get('h24', DASH)}%"
         f"   VOL24 ${hum((p.get('volume') or {}).get('h24'))}",
         f" FDV ${hum(p.get('fdv'))}   MCAP ${hum(p.get('marketCap'))}   pairs {d['n_pairs']}",
         "─" * W,
         " POOL (the actual exit door)",
         f"   liquidity ${hum(liq.get('usd'))}   =  {hum(liq.get('base'))} {base.get('symbol')}"
         f"  +  {hum(liq.get('quote'))} {quote.get('symbol')}",
         f"   liq/FDV {liq.get('usd', 0) / p['fdv']:.1%}" if liq.get("usd") and p.get("fdv") else f"   liq/FDV {DASH}",
         f"   LP locked/burned: {d.get('lp_locked_pct', DASH)}%"
         if d.get("lp_locked_pct") is not None else "   LP locked/burned: — (pump.fun curve holds pre-graduation liquidity)"
         if d["pumpfun"] else "   LP locked/burned: unavailable",
         f"   24h flow: {tx.get('buys', DASH)} buys / {tx.get('sells', DASH)} sells",
         "─" * W]
    hs = d.get("holders_summary")
    L.append(" SUPPLY & HOLDERS")
    oc = d.get("onchain", {})
    if oc.get("supply") is not None:
        L.append(f"   supply {hum(oc['supply'])} [solana rpc]")
    if hs:
        L.append(f"   holders {hs.get('total_holders', DASH)}   top-10 {hs['top10_pct']:.1f}%"
                 f"   insider-cluster {hs['insider_pct_top']:.1f}%"
                 f"   insider networks {hs['insider_networks']} [rugcheck graph]")
    elif "goplus" in d and "error" not in d["goplus"]:
        gp = d["goplus"]
        L.append(f"   holders {gp.get('holder_count', DASH)}   creator holds {gp.get('creator_percent', DASH)}"
                 f"   taxes buy {gp.get('buy_tax', DASH)} / sell {gp.get('sell_tax', DASH)} [goplus]")
    else:
        L.append(f"   holder analysis unavailable ({(d.get('rugcheck') or {}).get('error') or (d.get('goplus') or {}).get('error', 'no source')})")
    L.append("─" * W)
    L.append(" FLAGS" + ("" if d["flags"] else "   (none tripped — NOT a safety certification)"))
    for fl in d["flags"]:
        L.append(f"   ⚠ {fl}")
    for n in d["notes"]:
        L.append(f"   · {n}")
    L.append("─" * W)
    vis = f"https://app.bubblemaps.io/{'sol' if d['chain'] == 'solana' else d['chain']}/token/{d['address']}"
    L.append(f" VISUAL holder map: {vis}")
    L.append(" SRC dexscreener (px/pool/flow) · rugcheck (holders/authorities/insiders)"
             " · solana rpc (supply) · goplus (evm)" )
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
