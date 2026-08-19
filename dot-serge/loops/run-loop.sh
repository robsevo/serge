#!/usr/bin/env bash
# Serge loop runner — the generic outer-loop harness ("my job is to write loops").
#
# A loop is a directory  ~/.serge/loops/<name>/  containing a loop.conf that
# defines build_prompt() (and optionally post_run()). This runner supplies
# everything every loop needs and nothing loop-specific:
#
#   trigger (systemd timer/path unit or manual)
#     → guards (kill switches, single-flight lock, per-day caps, budget-cap flag)
#     → build_prompt()   sensor: decides IF there is work and writes the prompt
#     → serge -p --yolo  one bounded headless run (--max-turns, --max-budget-usd)
#     → tripwire         constitution hash must not change, else ALL loops die
#     → journal          one JSONL line per run with cost/turns/outcome
#     → post_run()       actuator: commit state (offsets, ledgers, checkboxes)
#
# loop.conf contract (sourced into this shell; may override the LOOP_* defaults):
#   build_prompt()  MUST write the prompt to "$PROMPT_FILE".
#                   return 0 → proceed; return 3 → quiet skip (no work, $0);
#                   anything else → journaled as a build error.
#                   Runs IN-SHELL, so it may set LOOP_CWD/LOOP_MODEL per run.
#   post_run RC OUT  optional; RC = serge exit code, OUT = result JSON path.
#   LOOP_ENV=(K=V …) optional; appended to the per-run SERGE_ENV_FILE (the ONLY
#                   way to set serge knobs — the wrapper sources its env file
#                   with `set -a`, clobbering anything merely exported here).
#
# Kill switches: SERGE_LOOPS_DISABLE=1 | ~/.serge/loops/DISABLED | <loop>/DISABLED
# Manual kick:   run-loop.sh <name> --now   (bypasses the per-loop daily cap only)
# Test hook:     SERGE_LOOP_BIN=<stub> replaces the serge binary (stub-serge takes
#                the prompt as its FINAL positional arg — which is why we pass it
#                positionally, matching evals/run.mjs).
#
# Exit codes: 0 normal (including skip/capped/API failure — timers keep cadence);
#             64 usage/config error (systemd shows the unit as failed).
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"
LOOPS="$SH/loops"
NAME="${1:-}"
NOW=0; [ "${2:-}" = "--now" ] && NOW=1
[ -n "$NAME" ] || { echo "usage: run-loop.sh <loop-name> [--now]" >&2; exit 64; }
DIR="$LOOPS/$NAME"
CONF="$DIR/loop.conf"
[ -f "$CONF" ] || { echo "run-loop: no loop '$NAME' ($CONF missing)" >&2; exit 64; }

# ── kill switches ────────────────────────────────────────────────────────────
[ "${SERGE_LOOPS_DISABLE:-0}" = "1" ] && exit 0
[ -f "$LOOPS/DISABLED" ] && exit 0
[ -f "$DIR/DISABLED" ] && exit 0

# ── single-flight lock (fd 9 held for the process lifetime) ─────────────────
exec 9>"$DIR/.lock"
flock -n 9 || exit 0            # a previous invocation is still running

mkdir -p "$DIR/state"
JOURNAL="$DIR/journal.jsonl"
PROMPT_FILE="$DIR/state/.prompt"
TODAY="$(date -u +%F)"

count_runs_today() {           # count journaled REAL runs (ran:true) in a journal file
  python3 - "$1" "$TODAY" 2>/dev/null <<'PY' || echo 0
import json, sys
n = 0
try:
    for line in open(sys.argv[1]):
        try: d = json.loads(line)
        except Exception: continue
        if d.get("day") == sys.argv[2] and d.get("ran"): n += 1
except FileNotFoundError:
    pass
print(n)
PY
}

journal() {                    # journal ran=<0|1> rc=<n> note=<txt> [cost=..] [turns=..] [summary=..]
  python3 - "$JOURNAL" "$NAME" "$TODAY" "$@" <<'PY'
import json, sys, datetime
path, name, day, *kv = sys.argv[1:]
d = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
     "loop": name, "day": day}
for pair in kv:
    k, _, v = pair.partition("=")
    if k == "ran": d[k] = v == "1"
    elif k in ("rc", "turns", "duration_s"):
        try: d[k] = int(v)
        except ValueError: d[k] = v
    elif k == "cost":
        try: d[k] = float(v)
        except ValueError: d[k] = v
    else: d[k] = v
with open(path, "a") as f:
    f.write(json.dumps(d) + "\n")
PY
}

notify_line() {                # append one "- [ ] ..." line to the notification queue
  local n="$SH/NOTIFICATIONS.md"
  # model-written appends don't always end with \n — repair before appending
  [ -f "$n" ] && [ -n "$(tail -c1 "$n" 2>/dev/null)" ] && printf '\n' >> "$n"
  printf -- "- [ ] %s %s\n" "$(date -u +%F)" "$1" >> "$n"
}

# ── defaults (loop.conf may override any of these) ───────────────────────────
LOOP_MODEL="local-coder"           # router seat via OPENAI_MODEL; "" = wrapper default
LOOP_MAX_TURNS=15
LOOP_MAX_BUDGET_USD="0.50"
LOOP_TIMEOUT=900                   # wall-clock seconds for the serge call
LOOP_CWD="$DIR/state"              # where serge runs
LOOP_MAX_RUNS_PER_DAY=24           # per-loop cap on REAL runs (skips don't count)
LOOP_EXTRA_ARGS=()
LOOP_ENV=()
LOOP_BIN="${SERGE_LOOP_BIN:-$HOME/.local/bin/serge}"   # the real wrapper (NOT serge-resume)
# Files no loop may EVER change. Hash mismatch after a run = hard-kill all loops.
LOOP_TRIPWIRE_GLOBS="$SH/CONSTITUTION.trimmed.v2.md $SH/CONSTITUTION.md $SH/council.md $SH/agents/*.md $SH/commands/*.md"

# shellcheck disable=SC1090
. "$CONF"

# ── per-day caps: per-loop (--now bypasses), then global (never bypassed) ───
runs_today="$(count_runs_today "$JOURNAL")"
if [ "$NOW" -eq 0 ] && [ "$runs_today" -ge "$LOOP_MAX_RUNS_PER_DAY" ]; then
  journal ran=0 rc=0 note="per-loop daily cap reached ($runs_today/$LOOP_MAX_RUNS_PER_DAY)"
  exit 0
fi
GLOBAL_CAP="${SERGE_LOOPS_GLOBAL_MAX_PER_DAY:-100}"
total_today=0
for j in "$LOOPS"/*/journal.jsonl; do
  [ -f "$j" ] && total_today=$((total_today + $(count_runs_today "$j")))
done
if [ "$total_today" -ge "$GLOBAL_CAP" ]; then
  journal ran=0 rc=0 note="global daily cap reached ($total_today/$GLOBAL_CAP)"
  exit 0
fi

# ── budget-cap pre-check (cheaper than eating the wrapper's exit-1) ─────────
if [ -f "$SH/monitor/.budget-capped" ]; then
  journal ran=0 rc=0 note="budget-capped (.budget-capped present); standing down until reset/--uncap"
  exit 0
fi

# ── sensor: is there work? ───────────────────────────────────────────────────
rm -f "$PROMPT_FILE"
build_prompt; brc=$?
if [ "$brc" -eq 3 ]; then exit 0; fi                       # quiet skip — no work
if [ "$brc" -ne 0 ] || [ ! -s "$PROMPT_FILE" ]; then
  journal ran=0 rc="$brc" note="build_prompt failed or wrote no prompt"
  exit 0
fi

# ── per-run env file: the wrapper sources SERGE_ENV_FILE with set -a, so this
#    (not export) is how loop knobs reach serge without serge.env clobbering ──
RUN_ENV="$DIR/state/run.env"
{
  cat "$LOOPS/serge-loop.env" 2>/dev/null || true
  for kv in "${LOOP_ENV[@]}"; do [ -n "$kv" ] && printf '%s\n' "$kv"; done
} > "$RUN_ENV"

# ── tripwire pre-hash ────────────────────────────────────────────────────────
trip_hash() { # shellcheck disable=SC2086
  { for f in $LOOP_TRIPWIRE_GLOBS; do [ -f "$f" ] && cat "$f"; done; } 2>/dev/null | sha256sum | cut -d' ' -f1
}
pre_hash="$(trip_hash)"

# ── one bounded headless serge run ───────────────────────────────────────────
OUT="$DIR/last-run.json"
ERRLOG="$DIR/stderr.log"
[ -f "$ERRLOG" ] && [ "$(stat -c%s "$ERRLOG" 2>/dev/null || echo 0)" -gt 1048576 ] && : > "$ERRLOG"
{ echo "── $(date -u +%FT%TZ) $NAME ──"; } >> "$ERRLOG"

MODEL_ENV=()
[ -n "$LOOP_MODEL" ] && MODEL_ENV=(OPENAI_MODEL="$LOOP_MODEL")
# LOOP_BIN may be multi-word (e.g. SERGE_LOOP_BIN="node …/stub-serge.mjs")
read -ra LOOP_BIN_CMD <<< "$LOOP_BIN"

start=$(date +%s)
( cd "$LOOP_CWD" 2>/dev/null || cd "$DIR/state"
  exec timeout "$LOOP_TIMEOUT" env "${MODEL_ENV[@]}" \
    SERGE_ENV_FILE="$RUN_ENV" \
    SERGE_STOP_FAILURE_SENTINEL="$DIR/state/stop-failure.sentinel" \
    SERGE_LOOP_ACTIVE=1 \
    "${LOOP_BIN_CMD[@]}" --yolo -p \
    --output-format json --max-turns "$LOOP_MAX_TURNS" \
    --max-budget-usd "$LOOP_MAX_BUDGET_USD" \
    "${LOOP_EXTRA_ARGS[@]}" "$(cat "$PROMPT_FILE")"
) > "$OUT" 2>> "$ERRLOG"
rc=$?
dur=$(( $(date +%s) - start ))

# ── tripwire post-hash: any change to the brain kills ALL loops, loudly ─────
post_hash="$(trip_hash)"
if [ "$post_hash" != "$pre_hash" ]; then
  touch "$LOOPS/DISABLED"
  notify_line "🚨 TRIPWIRE: loop '$NAME' run coincided with a constitution/agent-prompt change — ALL loops disabled (rm ~/.serge/loops/DISABLED after review)"
  command -v notify-send >/dev/null 2>&1 && notify-send "serge loops KILLED" "tripwire: brain files changed during loop '$NAME'" 2>/dev/null
  journal ran=1 rc="$rc" duration_s="$dur" note="TRIPWIRE — brain files changed; loops disabled"
  exit 0
fi

# ── classify + journal ───────────────────────────────────────────────────────
outcome="ok"
if [ "$rc" -eq 124 ]; then outcome="timeout"
elif [ "$rc" -ne 0 ] && tail -8 "$ERRLOG" 2>/dev/null | grep -q "daily spend cap reached"; then outcome="capped"
elif [ "$rc" -ne 0 ] && tail -8 "$ERRLOG" 2>/dev/null | grep -q "can't reach the model router"; then outcome="router-down"
elif [ "$rc" -ne 0 ]; then outcome="error"
fi
meta="$(python3 - "$OUT" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    cost = d.get("total_cost_usd") or 0
    turns = d.get("num_turns") or 0
    s = (d.get("result") or d.get("subtype") or "")[:200].replace("\n", " ")
    print(f"{cost} {turns} {s or 'no-result-text'}")
except Exception:
    print("0 0 unparseable")
PY
)" || meta="0 0 unparseable"
cost="${meta%% *}"; rest="${meta#* }"; turns="${rest%% *}"; summary="${rest#* }"
journal ran=1 rc="$rc" outcome="$outcome" duration_s="$dur" cost="$cost" turns="$turns" summary="$summary"

# ── actuator: let the loop commit its state (offsets, ledgers, checkboxes) ──
if type post_run >/dev/null 2>&1 && [ "$outcome" != "capped" ] && [ "$outcome" != "router-down" ]; then
  post_run "$rc" "$OUT" || journal ran=0 rc=0 note="post_run failed (state not committed)"
fi

exit 0
