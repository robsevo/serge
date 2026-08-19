#!/usr/bin/env python3
"""Weather via Open-Meteo — free, no API key. stdlib only.

Usage:
  python3 weather.py now "CITY"                     current conditions + today hi/lo
  python3 weather.py forecast "CITY" [--days N]     daily forecast (1-16 days, default 7)
  python3 weather.py spread "CITY" YYYY-MM-DD       ensemble daily-high spread (143 members,
                                                    4 independent NWP centers) — real uncertainty
  python3 weather.py history "CITY" START END       ERA5 reanalysis daily history (~5-day lag)
  --json on any command prints raw JSON instead of text.

Logic ported from weather-edge (Polymarket temp-market bot). Verified base URLs
and the ensemble model ids (ECMWF's is `ecmwf_ifs025` — `ecmwf_ifs_025` is HTTP 400).
"""
import json
import random
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Half-configured IPv6 on this box stalls every python HTTPS connect ~16s
# (AAAA tried first). Force IPv4 at the getaddrinfo level — covers stdlib urllib.
_orig_gai = socket.getaddrinfo
socket.getaddrinfo = lambda host, port, family=0, *a, **kw: _orig_gai(
    host, port, socket.AF_INET, *a, **kw
)

GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
ENSEMBLE_URL = "https://ensemble-api.open-meteo.com/v1/ensemble"
# gfs_seamless(NCEP) + icon_seamless(DWD) + ecmwf_ifs025(ECMWF) + gem_global(CMC)
ENSEMBLE_MODELS = "gfs_seamless,icon_seamless,ecmwf_ifs025,gem_global"

TIMEOUT = 30
RETRYABLE = {429, 500, 502, 503, 504}
MAX_RETRIES = 3

DAILY_VARS = ("temperature_2m_max,temperature_2m_min,precipitation_sum,"
              "precipitation_probability_max,windspeed_10m_max,weathercode")

WMO = {
    0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "overcast",
    45: "fog", 48: "rime fog", 51: "light drizzle", 53: "drizzle",
    55: "heavy drizzle", 56: "freezing drizzle", 57: "heavy freezing drizzle",
    61: "light rain", 63: "rain", 65: "heavy rain", 66: "freezing rain",
    67: "heavy freezing rain", 71: "light snow", 73: "snow", 75: "heavy snow",
    77: "snow grains", 80: "light showers", 81: "showers", 82: "violent showers",
    85: "snow showers", 86: "heavy snow showers", 95: "thunderstorm",
    96: "thunderstorm w/ hail", 99: "thunderstorm w/ heavy hail",
}


def get_json(base_url, params):
    """GET with bounded retry/backoff on 429/5xx; honors Retry-After."""
    url = base_url + "?" + urllib.parse.urlencode(params)
    last_err = None
    for attempt in range(MAX_RETRIES + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "serge-weather/1.0"})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code not in RETRYABLE:
                body = e.read()[:200].decode("utf-8", "replace")
                sys.exit(f"ERROR: HTTP {e.code} from {base_url}: {body}")
            last_err = f"HTTP {e.code} from {base_url}"
            retry_after = e.headers.get("Retry-After") if e.headers else None
            delay = (float(retry_after) if e.code == 429 and retry_after
                     else 1.0 * (2 ** attempt) + random.uniform(0, 0.1))
        except (urllib.error.URLError, socket.timeout, TimeoutError) as e:
            last_err = f"network error for {base_url}: {e}"
            delay = 1.0 * (2 ** attempt) + random.uniform(0, 0.1)
        if attempt < MAX_RETRIES:
            time.sleep(delay)
    sys.exit(f"ERROR: {last_err} after {MAX_RETRIES + 1} attempts")


def geocode(city):
    data = get_json(GEOCODE_URL, {"name": city, "count": 1, "language": "en"})
    results = data.get("results") or []
    if not results:
        sys.exit(f"ERROR: no geocoding match for {city!r}")
    r = results[0]
    where = ", ".join(x for x in (r.get("name"), r.get("admin1"), r.get("country")) if x)
    return r["latitude"], r["longitude"], r.get("timezone", "auto"), where


def c_to_f(c):
    return c * 9.0 / 5.0 + 32.0


def fmt_temp(c):
    return f"{c:.1f}°C/{c_to_f(c):.0f}°F"


def daily_rows(daily):
    times = daily.get("time") or []
    rows = []
    for i, day in enumerate(times):
        def v(key):
            series = daily.get(key) or []
            return series[i] if i < len(series) else None
        rows.append({
            "date": day,
            "high_c": v("temperature_2m_max"),
            "low_c": v("temperature_2m_min"),
            "precip_mm": v("precipitation_sum"),
            "precip_prob_pct": v("precipitation_probability_max"),
            "wind_max_kmh": v("windspeed_10m_max"),
            "conditions": WMO.get(v("weathercode"), "?"),
        })
    return rows


def print_days(rows):
    for r in rows:
        hi = fmt_temp(r["high_c"]) if r["high_c"] is not None else "?"
        lo = fmt_temp(r["low_c"]) if r["low_c"] is not None else "?"
        precip = f"{r['precip_mm']:.1f}mm" if r["precip_mm"] is not None else "?"
        prob = f"{r['precip_prob_pct']:.0f}%" if r["precip_prob_pct"] is not None else "-"
        wind = f"{r['wind_max_kmh']:.0f}km/h" if r["wind_max_kmh"] is not None else "?"
        print(f"{r['date']}  hi {hi:>14}  lo {lo:>14}  precip {precip:>7} ({prob:>4})"
              f"  wind {wind:>8}  {r['conditions']}")


def cmd_now(city, as_json):
    lat, lon, tz, where = geocode(city)
    data = get_json(FORECAST_URL, {
        "latitude": lat, "longitude": lon, "timezone": tz,
        "current_weather": "true", "daily": DAILY_VARS, "forecast_days": 1,
    })
    cur = data.get("current_weather") or {}
    today = daily_rows(data.get("daily") or {})
    if as_json:
        print(json.dumps({"location": where, "lat": lat, "lon": lon, "tz": tz,
                          "current": cur, "today": today}, indent=2))
        return
    cond = WMO.get(cur.get("weathercode"), "?")
    print(f"{where}  [{lat:.3f},{lon:.3f} {tz}]  source: open-meteo.com, as of {cur.get('time', '?')}")
    print(f"now: {fmt_temp(cur['temperature'])}  wind {cur.get('windspeed', '?')}km/h  {cond}")
    if today:
        print_days(today)


def cmd_forecast(city, days, as_json):
    lat, lon, tz, where = geocode(city)
    data = get_json(FORECAST_URL, {
        "latitude": lat, "longitude": lon, "timezone": tz,
        "daily": DAILY_VARS, "forecast_days": max(1, min(days, 16)),
    })
    rows = daily_rows(data.get("daily") or {})
    if as_json:
        print(json.dumps({"location": where, "tz": tz, "days": rows}, indent=2))
        return
    print(f"{where}  {len(rows)}-day forecast  [source: open-meteo.com]")
    print_days(rows)


def cmd_spread(city, date, as_json):
    lat, lon, tz, where = geocode(city)
    data = get_json(ENSEMBLE_URL, {
        "latitude": lat, "longitude": lon, "timezone": tz,
        "daily": "temperature_2m_max", "models": ENSEMBLE_MODELS,
        "start_date": date, "end_date": date,
    })
    daily = data.get("daily") or {}
    times = daily.get("time") or []
    if date not in times:
        sys.exit(f"ERROR: no ensemble row for {date} (range is ~today+14d)")
    idx = times.index(date)
    members = []
    for key, series in daily.items():
        if key == "time" or not key.startswith("temperature_2m_max"):
            continue
        if isinstance(series, list) and idx < len(series) and series[idx] is not None:
            members.append(float(series[idx]))
    if not members:
        sys.exit(f"ERROR: no ensemble members for {date}")
    members.sort()
    n = len(members)
    q = lambda p: members[min(n - 1, int(p * n))]
    out = {"location": where, "date": date, "members": n,
           "min_c": members[0], "p10_c": q(0.10), "median_c": q(0.50),
           "p90_c": q(0.90), "max_c": members[-1]}
    if as_json:
        print(json.dumps(out, indent=2))
        return
    print(f"{where}  daily-high ensemble for {date}  ({n} members, 4 NWP centers)")
    print(f"min {fmt_temp(out['min_c'])}  p10 {fmt_temp(out['p10_c'])}  "
          f"median {fmt_temp(out['median_c'])}  p90 {fmt_temp(out['p90_c'])}  "
          f"max {fmt_temp(out['max_c'])}")


def cmd_history(city, start, end, as_json):
    lat, lon, tz, where = geocode(city)
    data = get_json(ARCHIVE_URL, {
        "latitude": lat, "longitude": lon, "timezone": tz,
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_sum",
        "start_date": start, "end_date": end,
    })
    rows = daily_rows(data.get("daily") or {})
    if as_json:
        print(json.dumps({"location": where, "days": rows}, indent=2))
        return
    print(f"{where}  ERA5 reanalysis {start}..{end}  [source: open-meteo.com archive]")
    for r in rows:
        hi = fmt_temp(r["high_c"]) if r["high_c"] is not None else "?"
        lo = fmt_temp(r["low_c"]) if r["low_c"] is not None else "?"
        precip = f"{r['precip_mm']:.1f}mm" if r["precip_mm"] is not None else "?"
        print(f"{r['date']}  hi {hi:>14}  lo {lo:>14}  precip {precip}")


def main():
    args = [a for a in sys.argv[1:] if a != "--json"]
    as_json = "--json" in sys.argv
    if not args:
        sys.exit(__doc__.strip())
    cmd = args[0]
    if cmd == "now" and len(args) >= 2:
        cmd_now(args[1], as_json)
    elif cmd == "forecast" and len(args) >= 2:
        days = 7
        if "--days" in args:
            days = int(args[args.index("--days") + 1])
        cmd_forecast(args[1], days, as_json)
    elif cmd == "spread" and len(args) >= 3:
        cmd_spread(args[1], args[2], as_json)
    elif cmd == "history" and len(args) >= 4:
        cmd_history(args[1], args[2], args[3], as_json)
    else:
        sys.exit(__doc__.strip())


if __name__ == "__main__":
    main()
