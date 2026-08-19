#!/usr/bin/env bash
# Regression tests for the DETERMINISTIC silent-turn receipt in
# continue-on-unfinished.sh (Check 0 fallback).
#
# WHY THIS EXISTS (2026-08-15, user report "it has to let us know its done not
# just stop"): Check 0 already nudged the model to describe its own work, and
# that is the better output — but generating it needs a MODEL CALL. The case
# users actually hit is the free pool being drained (429 "No deployments
# available"), where the nudge cannot be answered: it goes out, nothing comes
# back, the anti-identical guard sees the same empty text, gives up, and the
# turn ends in silence. The receipt is the $0 local fallback for exactly that.
#
# The risk being guarded: this prints to the USER on the always-on stop path.
# T5 (never fires on a normal turn) and T6 (fail-open) matter most — a receipt
# on a turn that already replied is noise on every single stop.
set -uo pipefail

HOOK="${SERGE_CONTINUE_HOOK:-$HOME/.serge/continue-on-unfinished.sh}"
[ -x "$HOOK" ] || { echo "FATAL: $HOOK missing or not executable"; exit 1; }

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

# REDIRECT BOTH LIVE PATHS BEFORE THE FIRST run() — not later, next to the
# tests that obviously need them. Learned the hard way (2026-08-15): these were
# exported further down, so the earlier cases wrote the REAL
# ~/.serge/stop-failure.sentinel, clobbering a live session id and bumping its
# mtime — which is exactly what makes serge-resume treat a stale sentinel as
# fresh and resume a session nobody asked it to. A test that arms production
# machinery is worse than no test.
export SERGE_STOP_FAILURE_SENTINEL="$TMPDIR/sent"
export SERGE_QUERY_ERRORS_LOG="$TMPDIR/err.log"

# Snapshot the REAL sentinel so T14 can prove we never wrote it.
LIVE_SENTINEL="$HOME/.serge/stop-failure.sentinel"
LIVE_BEFORE="$(cat "$LIVE_SENTINEL" 2>/dev/null || echo ABSENT)"
LIVE_BEFORE_M="$(stat -c %Y "$LIVE_SENTINEL" 2>/dev/null || echo 0)"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
no(){ fail=$((fail+1)); echo "  FAIL $1 — $2"; }

mk_tx(){ # mk_tx <path> <with_tools:1|0>
  python3 - "$1" "$2" <<'PY'
import json, sys
rows=[{"type":"user","message":{"role":"user","content":"fix the thing"}}]
if sys.argv[2] == "1":
    rows.append({"type":"assistant","message":{"role":"assistant","content":[
        {"type":"tool_use","id":"1","name":"Read","input":{"file_path":"/r/a.ts"}},
        {"type":"tool_use","id":"2","name":"Edit","input":{"file_path":"/r/a.ts"}}]}})
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY
}
payload(){ # payload <tx> <sid> <last_msg>
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'Stop','session_id':sys.argv[2],
 'transcript_path':sys.argv[1],'last_assistant_message':sys.argv[3],'cwd':'/r'}))" "$1" "$2" "$3"
}
run(){ printf '%s' "$1" | "$HOOK" 2>/dev/null; }
has_sysmsg(){ printf '%s' "$1" | python3 -c "
import sys,json
try: d=json.load(sys.stdin)
except Exception: print('no'); raise SystemExit
print('yes' if d.get('systemMessage') else 'no')" 2>/dev/null || echo no; }

echo "test-silent-turn-receipt.sh"
TX="$TMPDIR/t.jsonl"; mk_tx "$TX" 1
P="$(payload "$TX" sid-a "")"

# T1 — the PREFERRED path still runs first: nudge the model, no receipt yet.
o1="$(run "$P")"
printf '%s' "$o1" | grep -q '"block"' && [ "$(has_sysmsg "$o1")" = no ] \
  && ok "pass 1 nudges the model, emits no receipt" \
  || no "pass 1 nudges the model, emits no receipt" "got: ${o1:0:80}"

# T2 — nudge did not move it: receipt, containing REAL transcript facts.
o2="$(run "$P")"
if [ "$(has_sysmsg "$o2")" = yes ]; then
  body="$(printf '%s' "$o2" | python3 -c "import sys,json;print(json.load(sys.stdin)['systemMessage'])")"
  printf '%s' "$body" | grep -q "tool call(s)" \
    && printf '%s' "$body" | grep -q "a.ts" \
    && ok "pass 2 emits a receipt naming tools and files" \
    || no "pass 2 emits a receipt naming tools and files" "body=$body"
else
  no "pass 2 emits a receipt naming tools and files" "no systemMessage"
fi

# T3 — a FRESH router-exhaustion error explains WHY it stopped.
printf '2026-01-01T00:00:00Z status=429 {"error":{"message":"No deployments available for selected model, Try again in 900 seconds"}}\n' > "$TMPDIR/err.log"
P3="$(payload "$TX" sid-c "")"
SERGE_QUERY_ERRORS_LOG="$TMPDIR/err.log" run "$P3" >/dev/null
o3="$(SERGE_QUERY_ERRORS_LOG="$TMPDIR/err.log" run "$P3")"
printf '%s' "$o3" | grep -q "cooling down" \
  && ok "fresh 429 in the log adds the cause line" \
  || no "fresh 429 in the log adds the cause line" "no cause line"

# T4 — a STALE log must NOT be blamed for this turn.
touch -d '2 hours ago' "$TMPDIR/err.log"
P4="$(payload "$TX" sid-d "")"
SERGE_QUERY_ERRORS_LOG="$TMPDIR/err.log" run "$P4" >/dev/null
o4="$(SERGE_QUERY_ERRORS_LOG="$TMPDIR/err.log" run "$P4")"
printf '%s' "$o4" | grep -q "cooling down" \
  && no "stale log is not blamed" "cause line appeared for a 2h-old error" \
  || ok "stale log is not blamed"

# T5 — THE ONE THAT MATTERS: a turn that actually replied never gets a receipt.
P5="$(payload "$TX" sid-e "Done — fixed the selector, tests pass.")"
leak=0
for _ in 1 2 3; do
  [ "$(has_sysmsg "$(run "$P5")")" = yes ] && leak=1
done
[ "$leak" = 0 ] && ok "normal turn never produces a receipt" \
                || no "normal turn never produces a receipt" "receipt leaked"

# T6 — fail-open. Garbage in must never break the stop path.
echo 'not json' | "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "unparseable payload exits 0" || no "unparseable payload exits 0" "nonzero exit"

# T7 — a silent turn with NO tools still says something rather than nothing.
TX2="$TMPDIR/t2.jsonl"; mk_tx "$TX2" 0
P7="$(payload "$TX2" sid-g "")"
run "$P7" >/dev/null
o7="$(run "$P7")"
if [ "$(has_sysmsg "$o7")" = yes ]; then ok "no-tool silent turn still reports"
else no "no-tool silent turn still reports" "stayed silent"; fi

# ── one-shot auto-retry arming ───────────────────────────────────────────────
# A cooled-router stop arms EXACTLY ONE resume by writing the sentinel that
# ~/.local/bin/serge-resume already watches. Reusing that path (rather than
# adding a retry loop) is deliberate: the wrapper has its own freshness check
# and MAX_RETRIES cap, so this cannot become the 240s/7-request storm that was
# removed earlier. T10 is the important one — re-arming the SAME outage is what
# would turn "once" back into a loop.
cooled(){ printf 'x status=429 {"error":{"message":"No deployments available for selected model"}}\n' > "$SERGE_QUERY_ERRORS_LOG"; }
armed(){ [ -f "$SERGE_STOP_FAILURE_SENTINEL" ] && echo yes || echo no; }
reset_arm(){ rm -f "$SERGE_STOP_FAILURE_SENTINEL" "$SERGE_STOP_FAILURE_SENTINEL.armed"; }

reset_arm; cooled
P8="$(payload "$TX" sid-h "")"
run "$P8" >/dev/null                                   # pass 1 = nudge
[ "$(armed)" = no ] && ok "nudge pass does not arm a retry" \
                    || no "nudge pass does not arm a retry" "armed too early"

o8="$(run "$P8")"                                      # pass 2 = give up
if [ "$(armed)" = yes ] && printf '%s' "$o8" | grep -q "Auto-retry ARMED"; then
  grep -q '^delay=[0-9]' "$SERGE_STOP_FAILURE_SENTINEL" \
    && ok "give-up arms one retry and announces it" \
    || no "give-up arms one retry and announces it" "sentinel has no delay= line"
else no "give-up arms one retry and announces it" "not armed or not announced"; fi

# T10 — the SAME outage must never arm twice.
rm -f "$SERGE_STOP_FAILURE_SENTINEL"                   # keep the .armed marker
P10="$(payload "$TX" sid-i "")"; run "$P10" >/dev/null; run "$P10" >/dev/null
[ "$(armed)" = no ] && ok "same outage never re-arms (just once)" \
                    || no "same outage never re-arms (just once)" "re-armed"

# T11 — a genuinely NEW outage may arm again.
sleep 1; cooled
P11="$(payload "$TX" sid-j "")"; run "$P11" >/dev/null; run "$P11" >/dev/null
[ "$(armed)" = yes ] && ok "a new outage re-arms" || no "a new outage re-arms" "did not arm"

# T12 — kill switch.
reset_arm; sleep 1; cooled
P12="$(payload "$TX" sid-k "")"
SERGE_AUTORETRY_COOLED=0 run "$P12" >/dev/null; SERGE_AUTORETRY_COOLED=0 run "$P12" >/dev/null
[ "$(armed)" = no ] && ok "SERGE_AUTORETRY_COOLED=0 disables arming" \
                    || no "SERGE_AUTORETRY_COOLED=0 disables arming" "armed anyway"

# T13 — a silent stop with no fresh router error must NOT arm. Arming on an
# ordinary silent turn would resume sessions the user never wanted resumed.
reset_arm; : > "$SERGE_QUERY_ERRORS_LOG"; touch -d '2 hours ago' "$SERGE_QUERY_ERRORS_LOG"
P13="$(payload "$TX" sid-l "")"; run "$P13" >/dev/null; run "$P13" >/dev/null
[ "$(armed)" = no ] && ok "silent stop without a fresh 429 never arms" \
                    || no "silent stop without a fresh 429 never arms" "armed wrongly"

# T14 — SELF-GUARD: prove the suite never armed production. Recorded at the top
# and checked here, because the failure this catches is silent by nature: the
# tests all pass while a live session gets resumed out from under the user.
now_live="$(cat "$LIVE_SENTINEL" 2>/dev/null || echo ABSENT)"
now_live_m="$(stat -c %Y "$LIVE_SENTINEL" 2>/dev/null || echo 0)"
if [ "$now_live" = "$LIVE_BEFORE" ] && [ "$now_live_m" = "$LIVE_BEFORE_M" ] \
   && [ ! -e "$LIVE_SENTINEL.armed" ]; then
  ok "suite left the real stop-failure.sentinel untouched"
else
  no "suite left the real stop-failure.sentinel untouched" \
     "the live sentinel changed — a test armed production"
fi

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
