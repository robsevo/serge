#!/usr/bin/env bash
# Serge /cost — quota fuel gauge (per-provider daily usage from today's
# transcripts, via quota.sh) + REAL OpenRouter spend vs the $20/month budget
# (2026-07-21: paid hatches haiku/sonnet/opus-paid + kimi-coder ride OpenRouter
# credit; budget-watchdog locks them at $3/day / $20/month). The dollar figures
# below are OpenRouter's own numbers — ground truth, not token estimates.
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
BUDGET="${SERGE_BUDGET_USD:-20}"

# --- Quota gauge (the real currency) -----------------------------------------
SERGE_QUOTA_QUIET=1 bash "$SERGE_HOME/quota.sh" 2>/dev/null || true
[ -f "$SERGE_HOME/monitor/quota-today.txt" ] && { cat "$SERGE_HOME/monitor/quota-today.txt"; echo; }
ph=$(cat "$SERGE_HOME/monitor/.paid-seat-hits" 2>/dev/null || echo 0)
if [ "${ph:-0}" -gt 0 ] 2>/dev/null; then
  echo "  ⚠ paid-seat tripwire: $ph paid turn(s) recorded today — see NOTIFICATIONS.md"
  echo
fi
if grep -qE '^OPENROUTER_PAID_API_KEY=LOCKED-BUDGET-CAP$' "$SERGE_HOME/router.env" 2>/dev/null; then
  echo "  🔒 paid seats LOCKED (budget cap hit) — auto-restores on day/month rollover"
  echo
fi

key="${OPENROUTER_API_KEY:-}"
if [ -z "$key" ] && [ -f "$SERGE_HOME/router.env" ]; then
  key=$(grep -E '^OPENROUTER_API_KEY=' "$SERGE_HOME/router.env" | head -1 | cut -d= -f2-)
  key=${key%$'\r'}; key=${key#[\"\']}; key=${key%[\"\']}
fi
[ -z "$key" ] && { echo "serge /cost: no OPENROUTER_API_KEY (checked env + $SERGE_HOME/router.env)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "serge /cost: python3 not found"; exit 0; }

keyjson=$(curl -sf --max-time 15 https://openrouter.ai/api/v1/key     -H "Authorization: Bearer $key" 2>/dev/null)
credjson=$(curl -sf --max-time 15 https://openrouter.ai/api/v1/credits -H "Authorization: Bearer $key" 2>/dev/null)

KEYJSON="$keyjson" CREDJSON="$credjson" BUDGET="$BUDGET" python3 - <<'PY'
import os, json
def data(s):
    try: return json.loads(s).get("data", {})
    except Exception: return {}
k = data(os.environ.get("KEYJSON", "")); c = data(os.environ.get("CREDJSON", ""))
if not k and not c:
    print("serge /cost: couldn't reach OpenRouter (network or bad key)"); raise SystemExit
def usd(x):
    try: return "$%.2f" % float(x)
    except Exception: return "n/a"
mon, day, wk, tot = k.get("usage_monthly"), k.get("usage_daily"), k.get("usage_weekly"), k.get("usage")
tc, tu = c.get("total_credits"), c.get("total_usage")
budget = float(os.environ.get("BUDGET", "50"))
print("  OpenRouter spend (paid hatches + free-qwen) — provider's own numbers")
print("  ────────────────────────")
line = f"  this month : {usd(mon)}"
if mon is not None:
    left = budget - float(mon)
    line += f"   ({usd(left)} left of ${int(budget)}/month cap)" + ("  ⚠ OVER" if left < 0 else "")
print(line)
print(f"  today      : {usd(day)}")
print(f"  this week  : {usd(wk)}")
print(f"  all-time   : {usd(tot)}")
if tc is not None and tu is not None:
    print(f"  credit left: {usd(float(tc) - float(tu))}  (of {usd(tc)} purchased)")
PY
