#!/usr/bin/env bash
# Tests for budget-watchdog.sh (paid-seat lockout model, 2026-07-21).
# Zero network, zero real systemctl: OpenRouter JSON is injected via
# SERGE_WATCHDOG_STUB_KEYJSON and systemctl is PATH-shimmed to a logger.
set -uo pipefail

WD="${SERGE_WATCHDOG_SCRIPT:-$HOME/.serge/budget-watchdog.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# --- fixture: temp SERGE_HOME + fake systemctl ---
mkdir -p "$T/sergehome/monitor" "$T/sergehome/projects" "$T/bin"
cat > "$T/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/systemctl.log"
exit 0
EOF
chmod +x "$T/bin/systemctl"
export PATH="$T/bin:$PATH"
export SERGE_HOME="$T/sergehome"
unset OPENROUTER_API_KEY 2>/dev/null || true

reset_env() {
  printf 'OPENROUTER_API_KEY=fake-real-key\nOPENROUTER_PAID_API_KEY=fake-real-key\n' > "$T/sergehome/router.env"
  rm -f "$T/sergehome/monitor/.paid-capped-day" "$T/sergehome/monitor/.paid-capped-month" \
        "$T/sergehome/monitor/.or-warned" "$T/sergehome/NOTIFICATIONS.md" "$T/systemctl.log"
  : > "$T/systemctl.log"
}
paid_line() { grep '^OPENROUTER_PAID_API_KEY=' "$T/sergehome/router.env"; }
restarts() { grep -c 'restart serge-router' "$T/systemctl.log" 2>/dev/null || true; }
stub() { export SERGE_WATCHDOG_STUB_KEYJSON="{\"data\":{\"usage_daily\":$1,\"usage_monthly\":$2}}"; }
export SERGE_WATCHDOG_STUB_CREDJSON='{"data":{"total_credits":133,"total_usage":113.18}}'

# 1. under both caps → untouched, spend cache written with real numbers
reset_env; stub 0.10 1.25
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=fake-real-key" ] \
   && [ "$(restarts)" = "0" ] \
   && python3 -c "import json;d=json.load(open('$T/sergehome/monitor/or-spend.json'));assert d['monthly']==1.25 and d['daily']==0.10 and abs(d['credit_left']-19.82)<0.001" 2>/dev/null; then
  ok "under caps: no action, or-spend.json has the real numbers"
else bad "under caps: unexpected action or bad spend cache"; fi

# 2. daily breach → paid key LOCKED, router restarted, notification written
reset_env; stub 3.50 4.00
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=LOCKED-BUDGET-CAP" ] \
   && [ "$(restarts)" = "1" ] \
   && grep -q 'LOCKED' "$T/sergehome/NOTIFICATIONS.md"; then
  ok "daily breach: paid seats locked + router restarted + notified"
else bad "daily breach: lock did not happen correctly"; fi

# 3. still locked, still same day → NO second restart (no flapping)
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=LOCKED-BUDGET-CAP" ] && [ "$(restarts)" = "1" ]; then
  ok "same-period re-run: stays locked, no restart flapping"
else bad "same-period re-run: flapped (restarts=$(restarts))"; fi

# 4. day rolls over + spend back under caps → key restored, flags cleared
stub 0.00 4.00
printf '2001-01-01\n' > "$T/sergehome/monitor/.paid-capped-day"
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=fake-real-key" ] \
   && [ ! -f "$T/sergehome/monitor/.paid-capped-day" ] && [ "$(restarts)" = "2" ]; then
  ok "rollover: key restored + flags cleared + router restarted"
else bad "rollover: restore failed (line=$(paid_line) restarts=$(restarts))"; fi

# 5. monthly breach → lock with month flag
reset_env; stub 0.50 20.00
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=LOCKED-BUDGET-CAP" ] \
   && [ "$(cat "$T/sergehome/monitor/.paid-capped-month")" = "$(date -u +%Y-%m)" ]; then
  ok "monthly breach: locked with month flag"
else bad "monthly breach: lock failed"; fi

# 6. malformed API JSON → fail-safe, nothing touched
reset_env; export SERGE_WATCHDOG_STUB_KEYJSON='garbage not json'
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=fake-real-key" ] && [ "$(restarts)" = "0" ]; then
  ok "malformed API response: fail-safe no-op"
else bad "malformed API response: acted on garbage"; fi

# 7. 50% warning fires once per month, not every 5 minutes
reset_env; stub 0.10 10.50
bash "$WD"; bash "$WD"
warns=$(grep -c 'past 50%' "$T/sergehome/NOTIFICATIONS.md" 2>/dev/null || true)
if [ "$warns" = "1" ] && [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=fake-real-key" ]; then
  ok "50% soft warning: fired exactly once, no lock"
else bad "50% soft warning: fired $warns times"; fi

# 8b. --uncap override: daily breach + .uncap-day=today → NO lock…
reset_env; stub 3.50 4.00
date -u +%F > "$T/sergehome/monitor/.uncap-day"
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=fake-real-key" ] && [ "$(restarts)" = "0" ]; then
  ok "uncap-day: daily cap lifted for today, no lock"
else bad "uncap-day: daily cap still locked"; fi
# …but the MONTHLY cap is never lifted by uncap
stub 3.50 25.00
bash "$WD"
if [ "$(paid_line)" = "OPENROUTER_PAID_API_KEY=LOCKED-BUDGET-CAP" ]; then
  ok "uncap-day: monthly cap still enforced"
else bad "uncap-day: monthly cap bypassed!"; fi
rm -f "$T/sergehome/monitor/.uncap-day"

# 8. legacy whole-router stop flag → migrated (router started, flag removed)
reset_env; stub 0.10 1.00
: > "$T/sergehome/monitor/.budget-capped"
bash "$WD"
if [ ! -f "$T/sergehome/monitor/.budget-capped" ] && grep -q 'start serge-router' "$T/systemctl.log"; then
  ok "legacy .budget-capped: migrated (router started, flag gone)"
else bad "legacy .budget-capped: not migrated"; fi

# 9. REGRESSION (2026-07-22): the paid-seat tripwire must count turns recorded
# under the SERVED upstream id, not just the seat name. A transcript logs
# "haiku-paid" only when the seat was named explicitly; a FALLBACK into it logs
# "anthropic/claude-haiku-4.5". Fallback is the path that spends money nobody
# asked for, and the seat-name-only pattern was blind to exactly that — it
# reported 0 paid turns through a day that billed $6.19 of Haiku.
reset_env; stub 0.10 1.00
mkdir -p "$T/sergehome/projects/proj"
cat > "$T/sergehome/projects/proj/session.jsonl" <<'EOF'
{"type":"assistant","message":{"model":"anthropic/claude-haiku-4.5","usage":{"input_tokens":35548,"output_tokens":88}}}
{"type":"assistant","message":{"model":"qwen/qwen3-coder-next","usage":{"input_tokens":100,"output_tokens":10}}}
{"type":"assistant","message":{"model":"local-coder","usage":{"input_tokens":50,"output_tokens":5}}}
EOF
rm -f "$T/sergehome/monitor/.paid-seat-hits"
bash "$WD"
hits=$(cat "$T/sergehome/monitor/.paid-seat-hits" 2>/dev/null || echo 0)
if [ "$hits" = "2" ] && grep -q 'paid-seat turn' "$T/sergehome/NOTIFICATIONS.md" 2>/dev/null; then
  ok "served-name detection: fallback-served paid turns counted + notified"
else bad "served-name detection: counted '$hits' (want 2 — haiku + qwen, not local-coder)"; fi

# 10. The free workhorse must NOT be mistaken for a paid seat (guards against
# an over-broad pattern silently flagging every turn as billing).
reset_env; stub 0.10 1.00
cat > "$T/sergehome/projects/proj/session.jsonl" <<'EOF'
{"type":"assistant","message":{"model":"local-coder","usage":{"input_tokens":50,"output_tokens":5}}}
{"type":"assistant","message":{"model":"cloud-brain","usage":{"input_tokens":50,"output_tokens":5}}}
EOF
rm -f "$T/sergehome/monitor/.paid-seat-hits"
bash "$WD"
hits=$(cat "$T/sergehome/monitor/.paid-seat-hits" 2>/dev/null || echo 0)
if [ "$hits" = "0" ]; then
  ok "free seats are not flagged as paid"
else bad "free seats misflagged as paid (hits=$hits)"; fi

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — budget watchdog trustworthy"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
