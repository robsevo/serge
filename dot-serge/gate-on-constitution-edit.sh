#!/usr/bin/env bash
# PreToolUse hook — gate constitution-class edits against the eval baseline.
#
# Fires before Edit/Write/MultiEdit. If the target is a behavior-defining file
# (CONSTITUTION*, council.md, agents/*.md, commands/*.md), it compares the most
# recent eval results to the saved baseline and reports whether behavior is
# already regressed.
#
# SEMANTIC NOTE: a PreToolUse hook fires BEFORE the edit lands, so it cannot
# detect a regression caused by *this* edit. What it enforces is the ratchet
# "don't keep editing the constitution while behavior is already regressed vs
# baseline" — and it guarantees a baseline exists so post-edit `--gate` works.
# The real post-edit catch is `node ~/.serge/evals/run.mjs --gate` after the edit.
#
# ── WHY THIS NO LONGER RUNS THE SUITE (2026-08-14) ─────────────────────────
# It used to call `run.mjs --gate` inline and wait. That could not work:
#
#   18 golden tasks x 300 s timeout, sequential, +8 s pacing, +45 s cooldown and
#   one full retry per rate-limited task ⇒ a worst case near 3.3 HOURS, run
#   inside a hook whose harness budget is 480 s.
#
# So the sweep was killed mid-task on every slow run. The damage was not just
# "no answer": the hook blocked the user's edit for the whole 8 minutes first,
# and `run.mjs` had already overwritten results/latest.json with the truncated
# run — so the NEXT reader of latest.json saw a handful of tasks and no record
# that the rest never ran. A ceiling that does not cover the sum of the inner
# timeouts is exactly the bug class stop-checks.sh's header warns about; this
# hook was the instance of it.
#
# The fix is to stop pretending. The suite has two schedulers that CAN afford
# it — `serge-loop@eval-gate` nightly and the Stop-stage gate — so this hook now
# reads their evidence, states how old it is, and returns in milliseconds. It
# reports a stale verdict as stale rather than manufacturing a fresh one it has
# no room to compute.
#
# run.mjs grew `--budget-sec` for callers with a real deadline: it stops STARTING
# tasks that cannot finish, records them in `skipped`, and marks the run
# `partial` so nothing downstream mistakes "not run" for "passed". Partial runs
# are refused as baselines (that would silently shrink what is gated at all).
#
# Behavior:
#   - default: ADVISORY (never blocks; shows a systemMessage)
#   - SERGE_GATE_ENFORCE=1: DENY the edit on a genuine regression
#   - infra/provider errors are never treated as regressions (fail-open)
#
# Toggles:
#   SERGE_GATE_DISABLE=1        turn the hook off entirely
#   SERGE_GATE_ENFORCE=1        block edits on genuine regression (default: warn)
#   SERGE_GATE_MAX_AGE_SEC=N    call evidence stale past this age (default 86400)
#   SERGE_GATE_REFRESH=1        when stale, kick off a DETACHED budgeted refresh
#                               (default off — it spends free quota alongside the
#                               session that triggered it; opt in deliberately)
#   SERGE_GATE_REFRESH_BUDGET=N wall-clock budget for that refresh (default 900)
#   SERGE_GATE_DEBOUNCE_SEC=N   min gap between refresh spawns (default 900)
#   SERGE_GATE_MODEL=<alias>    model for eval runs (default: qwen-coder)
#   SERGE_GATE_MATCH=<regex>    grep -E pattern of paths to gate
#   SERGE_EVAL_DIR=<dir>        evals dir (default: ~/.serge/evals)
set -u

# --- fail-open + recursion guards (never block on infra problems) ---
[ "${SERGE_GATE_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ]         && exit 0   # inside an eval child
[ "${SERGE_GATE_ACTIVE:-0}" = "1" ]  && exit 0   # inside our own gate run
command -v python3 >/dev/null 2>&1   || exit 0
command -v node    >/dev/null 2>&1   || exit 0

input="$(cat)"

# --- parse tool name + edited file path from the PreToolUse JSON ---
eval "$(printf '%s' "$input" | python3 -c '
import sys, json, shlex
try: d = json.load(sys.stdin)
except Exception: d = {}
ti = d.get("tool_input") or {}
fp = ti.get("file_path") or ti.get("path") or ""
print("GATE_TOOL=" + shlex.quote(d.get("tool_name") or ""))
print("GATE_FILE=" + shlex.quote(fp))
' 2>/dev/null)" || exit 0

# --- only gate behavior-defining files ---
MATCH="${SERGE_GATE_MATCH:-/\.serge/(CONSTITUTION|council\.md|agents/.*\.md|commands/.*\.md)}"
printf '%s' "${GATE_FILE:-}" | grep -Eq "$MATCH" || exit 0

EVALS="${SERGE_EVAL_DIR:-$HOME/.serge/evals}"
RUN="$EVALS/run.mjs"
BASE="$EVALS/baseline/baseline.json"
LATEST="$EVALS/results/latest.json"
STAMP="$EVALS/.last-gate"

emit_allow_msg() { python3 -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1]}))' "$1"; }
emit_deny() {
  python3 -c 'import json,sys; m=sys.argv[1]; print(json.dumps({
    "hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":m},
    "reason":m,"systemMessage":m}))' "$1"
}

# --- can't gate without the harness or a baseline → advise, allow ---
[ -f "$RUN" ] || exit 0
if [ ! -f "$BASE" ]; then
  emit_allow_msg "serge-eval: no baseline yet — run \`node $RUN --baseline\` (cheap model) to enable constitution gating."
  exit 0
fi

MAX_AGE="${SERGE_GATE_MAX_AGE_SEC:-86400}"
now="$(date +%s 2>/dev/null || echo 0)"

# --- optional detached refresh when the evidence is stale --------------------
# Debounced and budgeted. Detached (setsid) so it survives this hook returning:
# a background child of a hook process is killed with the hook's process group
# when the harness reaps it, which would leave a half-written latest.json.
maybe_refresh() {
  [ "${SERGE_GATE_REFRESH:-0}" = "1" ] || return 0
  local debounce="${SERGE_GATE_DEBOUNCE_SEC:-900}"
  if [ -f "$STAMP" ]; then
    local last; last="$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)"
    [ $((now - last)) -lt "$debounce" ] && return 0
  fi
  touch "$STAMP" 2>/dev/null || true
  mkdir -p "$EVALS/results" 2>/dev/null || true
  SERGE_GATE_ACTIVE=1 SERGE_EVAL_MODEL="${SERGE_GATE_MODEL:-qwen-coder}" \
    setsid nohup node "$RUN" --gate \
      --budget-sec "${SERGE_GATE_REFRESH_BUDGET:-900}" \
      >"$EVALS/results/refresh.log" 2>&1 &
}

# --- read the freshest evidence; classify it -------------------------------
if [ ! -f "$LATEST" ]; then
  maybe_refresh
  emit_allow_msg "serge-eval: no eval results yet — gating is blind. Run \`node $RUN --gate\` (or wait for the nightly serge-loop@eval-gate) to give this ratchet something to compare against."
  exit 0
fi

eval "$(LATEST="$LATEST" BASE="$BASE" NOW="$now" python3 -c '
import os, sys, json, shlex
def q(k, v): print(f"{k}=" + shlex.quote(str(v)))
try:
    base = json.load(open(os.environ["BASE"])); latest = json.load(open(os.environ["LATEST"]))
except Exception:
    q("GATE_GENUINE_N", 0); sys.exit(0)
bp = {r["id"]: r.get("pass") for r in base.get("results", [])}
genuine = []; infra = []; improved = []
for r in latest.get("results", []):
    i = r.get("id"); was = bp.get(i); now_pass = r.get("pass")
    if was and not now_pass:
        if r.get("error") or (r.get("run", {}) or {}).get("timedOut"): infra.append(i)
        else: genuine.append(i)
    elif (was is False) and now_pass:
        improved.append(i)
q("GATE_GENUINE", " ".join(genuine)); q("GATE_GENUINE_N", len(genuine))
q("GATE_INFRA", " ".join(infra));     q("GATE_INFRA_N", len(infra))
q("GATE_IMPROVED", " ".join(improved))
# Evidence provenance: how old, and did it actually cover the suite?
try:
    age = int(float(os.environ["NOW"]) - os.path.getmtime(os.environ["LATEST"]))
except Exception:
    age = -1
q("GATE_AGE", age)
skipped = latest.get("skipped") or []
covered = len(latest.get("results", []))
# Coverage gap counts as partial even without the `skipped` field. Results
# written before that field existed carry no marker at all — the live file on
# 2026-08-14 held ONE task against a fourteen-task baseline, and the old hook
# read it as a clean verdict. Comparing counts catches that case too.
missing = max(0, len(bp) - covered)
q("GATE_PARTIAL", "1" if (latest.get("partial") or skipped or missing) else "0")
q("GATE_SKIPPED_N", len(skipped) or missing)
q("GATE_SCORED_N", covered)
q("GATE_EXPECTED_N", len(bp))
' 2>/dev/null)" || exit 0

# --- describe the evidence in one clause, never as a fresh result ----------
age="${GATE_AGE:--1}"
if [ "$age" -lt 0 ]; then       age_txt="age unknown"
elif [ "$age" -lt 3600 ]; then  age_txt="$((age / 60))m old"
else                            age_txt="$((age / 3600))h old"
fi
prov="evidence: ${GATE_SCORED_N:-0}/${GATE_EXPECTED_N:-0} task(s), $age_txt"
[ "${GATE_PARTIAL:-0}" = "1" ] && prov="$prov, PARTIAL — ${GATE_SKIPPED_N:-0} task(s) never ran"

stale=0
[ "$age" -ge 0 ] && [ "$age" -gt "$MAX_AGE" ] && stale=1
[ "$stale" = "1" ] && { maybe_refresh; prov="$prov — stale (>$((MAX_AGE / 3600))h)"; }

# --- decide ---
if [ "${GATE_GENUINE_N:-0}" -gt 0 ]; then
  msg="serge-eval ⚠ constitution gate: REGRESSION in [${GATE_GENUINE}] — these passed on baseline but fail in the last run ($prov). Fix the regression, or accept it with \`node $RUN --update-baseline\`."
  # A stale or partial verdict is not a basis for blocking an edit: the finding
  # may already be fixed, or may be an artifact of a run that got cut short.
  if [ "${SERGE_GATE_ENFORCE:-0}" = "1" ] && [ "$stale" = "0" ] && [ "${GATE_PARTIAL:-0}" = "0" ]; then
    emit_deny "$msg Edit blocked (SERGE_GATE_ENFORCE=1)."
  elif [ "${SERGE_GATE_ENFORCE:-0}" = "1" ]; then
    emit_allow_msg "$msg Not blocking: the evidence is stale or partial — re-run \`node $RUN --gate\` to get a verdict worth enforcing."
  else
    emit_allow_msg "$msg (advisory; set SERGE_GATE_ENFORCE=1 to block)."
  fi
  exit 0
fi

if [ "${GATE_INFRA_N:-0}" -gt 0 ]; then
  emit_allow_msg "serge-eval: could not verify [${GATE_INFRA}] (provider/router error, not a regression) — edit allowed ($prov)."
  exit 0
fi

if [ "$stale" = "1" ] || [ "${GATE_PARTIAL:-0}" = "1" ]; then
  emit_allow_msg "serge-eval: no regression in the last run, but $prov. Treat this as unverified — run \`node $RUN --gate\` for a current verdict."
  exit 0
fi

if [ -n "${GATE_IMPROVED:-}" ]; then
  emit_allow_msg "serge-eval ✓ gate green (improved: [${GATE_IMPROVED}]; $prov) — consider \`--update-baseline\`."
  exit 0
fi

# all green, fresh, nothing notable → silent allow
exit 0
