#!/usr/bin/env python3
"""Steam market/app research CLI — keyless endpoints only ($0, no API key, no login).

Every endpoint here was live-verified 2026-07-21. Endpoints that DON'T work are documented in
SKILL.md so they are never guessed at (e.g. ISteamApps/GetAppList 404s).

Usage:
  steam_query.py app <appid>          # name, price, genres, release, developer
  steam_query.py players <appid>      # concurrent players right now
  steam_query.py reviews <appid>      # review count + score breakdown
  steam_query.py news <appid> [n]     # latest news items
  steam_query.py search <term>        # storefront search (appid lookup)
  steam_query.py compare <id,id,...>  # side-by-side price/reviews/players

Fails loudly: a bad appid or a network error is reported, never silently defaulted.
"""
import json
import sys
import urllib.parse
import urllib.request

UA = {"User-Agent": "serge-steam-skill/1.0"}
TIMEOUT = 20


def _get(url: str):
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.load(r)
    except Exception as e:  # fail loudly with context — never a silent default
        raise SystemExit(f"steam_query: request failed for {url}\n  {type(e).__name__}: {e}")


def app_details(appid: str, filters="basic,price_overview,genres,release_date,developers,publishers"):
    url = f"https://store.steampowered.com/api/appdetails?appids={appid}&filters={filters}"
    d = _get(url)
    entry = d.get(str(appid)) or {}
    if not entry.get("success"):
        raise SystemExit(f"steam_query: appid {appid} not found or not visible in this region")
    return entry["data"]


def cmd_app(appid):
    a = app_details(appid)
    price = (a.get("price_overview") or {}).get("final_formatted") or ("Free" if a.get("is_free") else "n/a")
    print(f"name        : {a.get('name')}")
    print(f"appid       : {a.get('steam_appid')}")
    print(f"type        : {a.get('type')}")
    print(f"price       : {price}")
    disc = (a.get("price_overview") or {}).get("discount_percent")
    if disc:
        print(f"discount    : -{disc}%")
    print(f"genres      : {', '.join(g['description'] for g in a.get('genres', [])) or 'n/a'}")
    print(f"released    : {(a.get('release_date') or {}).get('date', 'n/a')}")
    print(f"developer   : {', '.join(a.get('developers', []) or []) or 'n/a'}")
    print(f"publisher   : {', '.join(a.get('publishers', []) or []) or 'n/a'}")


def cmd_players(appid):
    d = _get(f"https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid={appid}")
    resp = d.get("response", {})
    if resp.get("result") != 1:
        raise SystemExit(f"steam_query: no player data for appid {appid}")
    print(f"concurrent players: {resp.get('player_count'):,}")


def cmd_reviews(appid):
    d = _get(f"https://store.steampowered.com/appreviews/{appid}?json=1&num_per_page=0&language=all")
    q = d.get("query_summary") or {}
    total = q.get("total_reviews", 0)
    pos = q.get("total_positive", 0)
    pct = (pos / total * 100) if total else 0
    print(f"reviews     : {total:,}")
    print(f"positive    : {pos:,} ({pct:.1f}%)")
    print(f"score       : {q.get('review_score_desc', 'n/a')}")


def cmd_news(appid, n="3"):
    d = _get(f"https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid={appid}&count={n}&maxlength=200")
    for item in (d.get("appnews") or {}).get("newsitems", []):
        print(f"- {item.get('title')}  [{item.get('feedlabel')}]")
        print(f"  {item.get('url')}")


def cmd_search(term):
    q = urllib.parse.quote(term)
    d = _get(f"https://store.steampowered.com/api/storesearch/?term={q}&l=en&cc=US")
    items = d.get("items") or []
    if not items:
        raise SystemExit(f"steam_query: no store results for {term!r}")
    for it in items[:10]:
        price = (it.get("price") or {}).get("final")
        price_s = f"${price/100:.2f}" if isinstance(price, int) else ("Free" if it.get("price") == {} else "n/a")
        print(f"{it.get('id'):>8}  {it.get('name')[:52]:<52} {price_s}")


def cmd_compare(ids):
    print(f"{'appid':>8}  {'name':<30} {'price':>10} {'reviews':>9} {'players':>9}")
    for appid in [i.strip() for i in ids.split(",") if i.strip()]:
        try:
            a = app_details(appid)
            price = (a.get("price_overview") or {}).get("final_formatted") or ("Free" if a.get("is_free") else "n/a")
            rv = _get(f"https://store.steampowered.com/appreviews/{appid}?json=1&num_per_page=0&language=all")
            total = (rv.get("query_summary") or {}).get("total_reviews", 0)
            pl = _get(f"https://api.steampowered.com/ISteamUserStats/GetNumberOfCurrentPlayers/v1/?appid={appid}")
            pc = (pl.get("response") or {}).get("player_count", 0)
            print(f"{appid:>8}  {a.get('name','?')[:30]:<30} {price:>10} {total:>9,} {pc:>9,}")
        except SystemExit as e:
            print(f"{appid:>8}  ERROR: {e}")


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    table = {
        "app": cmd_app, "players": cmd_players, "reviews": cmd_reviews,
        "news": cmd_news, "search": cmd_search, "compare": cmd_compare,
    }
    if cmd not in table:
        raise SystemExit(f"steam_query: unknown command {cmd!r}\n{__doc__}")
    if not args:
        raise SystemExit(f"steam_query: {cmd} needs an argument\n{__doc__}")
    table[cmd](*args)


if __name__ == "__main__":
    main()
