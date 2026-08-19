---
name: weather
description: Weather lookups via Open-Meteo — current conditions, 1-16 day forecasts, cross-model ensemble uncertainty spread, and ERA5 historical daily data for any city worldwide. Free, keyless, deterministic; every answer sourced and dated.
whenToUse: Use whenever the user asks about weather — "what's the weather in X", temperature today/tomorrow/this week, forecasts, "will it rain", wind, "how hot was it on [past date]", climate/temperature history for a place, or when another task needs weather data (trip planning, event scheduling, sports conditions). Do NOT use for climate-science research questions — that's the researcher's job.
---

# Weather — Open-Meteo, $0, no key

One script: `scripts/weather.py` (plain `python3`, stdlib only, IPv4-forced for
this box). Text output by default, `--json` for raw.

| Ask | Run |
|---|---|
| Current conditions / today | `weather.py now "CITY"` |
| Forecast N days (1-16, default 7) | `weather.py forecast "CITY" --days N` |
| How certain is a forecast high? | `weather.py spread "CITY" YYYY-MM-DD` |
| Past weather (ERA5, ~5-day lag) | `weather.py history "CITY" START END` |

Notes that matter:

- **Geocoding is fuzzy** — "paris" hits Paris FR first; disambiguate with
  "Paris, Texas"-style queries when the user means somewhere smaller.
- **`spread`** returns the daily-high distribution across ~143 ensemble members
  from 4 independent NWP centers (GFS/ICON/ECMWF/GEM). A wide p10-p90 band means
  genuinely uncertain weather — say so instead of quoting one number.
- **Forecast vs observed**: Open-Meteo values are grid-cell model output, not
  station readings. Fine for "what's the weather"; for an official station
  record ("what did it hit at the airport"), say it's model-based.
- History is ERA5 reanalysis: authoritative, but lags ~5 days behind today.
- Temps print as `°C/°F` — quote whichever fits the user's locale.
