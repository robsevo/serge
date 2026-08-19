#!/usr/bin/env bash
# Stop-stage gate — the POST-EDIT complement to gate-on-constitution-edit.sh.
#
# Runs at end of turn (orchestrated by stop-checks.sh). Unlike the PreToolUse
# hook, this fires AFTER edits land, so it catches a regression caused by the
# constitution change you just made — the real post-edit catch.
#
# Cost control: it only runs the eval suite when a behavior-defining file's
# content HASH changed since the last gate (stored in evals/.const-hash). Normal
# turns — where you didn't touch the constitution — do a millisecond hash check
# and exit. So this costs nothing unless you actually edited Serge's brain.
#
# Contract (matches verify/review): a single {"systemMessage":…} JSON on stdout
# = non-blocking note; exit 2 + stderr = block the stop (agent must address).
#
# Toggles: SERGE_GATE_DISABLE, SERGE_GATE_ENFORCE, SERGE_GATE_MODEL,
#          SERGE_GATE_HASH_GLOBS (space-separated files/globs to hash),
#          SERGE_EVAL_DIR, SERGE_HOME.
set -uo pipefail

[ "${SERGE_GATE_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ]         && exit 0   # inside an eval child
[ "${SERGE_GATE_ACTIVE:-0}" = "1" ]  && exit 0   # inside our own gate run
command -v python3   >/dev/null 2>&1 || exit 0
command -v node      >/dev/null 2>&1 || exit 0
command -v sha256sum >/dev/null 2>&1 || exit 0

SH="${SERGE_HOME:-$HOME/.serge}"
EVALS="${SERGE_EVAL_DIR:-$SH/evals}"
RUN="$EVALS/run.mjs"
BASE="$EVALS/baseline/baseline.json"
LATEST="$EVALS/results/latest.json"
HASHF="$EVALS/.const-hash"

[ -f "$RUN" ] || exit 0

input="$(cat)"

# Re-entry guard: if a prior Stop hook already forced a continuation, don't loop.
HOOK_ACTIVE="$(printf '%s' "$input" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print("1" if d.get("stop_hook_active") else "0")
' 2>/dev/null || echo 0)"
[ "$HOOK_ACTIVE" = "1" ] && exit 0

# Hash the behavior-defining files. Default: the active constitution, council,
# and agent seat prompts. Override with SERGE_GATE_HASH_GLOBS.
# shellcheck disable=SC2086
hash_now() {
  local globs="${SERGE_GATE_HASH_GLOBS:-$SH/CONSTITUTION.trimmed.v2.md $SH/CONSTITUTION.md $SH/council.md $SH/agents/*.md}"
  { for f in $globs; do [ -f "$f" ] && cat "$f"; done; } 2>/dev/null | sha256sum | cut -d' ' -f1
}

now_hash="$(hash_now)"
prev_hash="$(cat "$HASHF" 2>/dev/null || echo '')"
[ "$now_hash" = "$prev_hash" ] && exit 0          # nothing behavior-defining changed → skip

emit_msg() { python3 -c 'import json,sys; print(json.dumps({"systemMessage": sys.argv[1], "suppressOutput": True}))' "$1"; }

# Constitution changed but we can't gate without a baseline.
if [ ! -f "$BASE" ]; then
  printf '%s' "$now_hash" > "$HASHF" 2>/dev/null || true
  emit_msg "serge-eval: a behavior-defining file changed, but there's no eval baseline — run \`node $RUN --baseline\` to enable post-edit gating."
  exit 0
fi

# DEFER by default (2026-07-18): the inline sweep ran the FULL golden-task
# suite synchronously inside the Stop hook — minutes of wall-clock. Worse, it
# regularly outlived the hook's timeout ceiling, so the harness killed it
# BEFORE the hash-update line below: .const-hash stayed stale (observed: dated
# Jun 22 on Jul 18) and EVERY clean stop re-launched the whole suite. The
# nightly eval-gate loop (serge-loop@eval-gate.timer, 03:30) already sweeps
# unconditionally and self-diagnoses, so interactive stops just note the
# change and settle the hash. SERGE_GATE_INLINE=1 restores the old inline
# blocking gate (used by the selftest; available for high-stakes edits).
if [ "${SERGE_GATE_INLINE:-0}" != "1" ]; then
  printf '%s' "$now_hash" > "$HASHF" 2>/dev/null || true
  emit_msg "serge-eval: behavior-defining files changed — full eval sweep deferred to the nightly eval-gate loop (03:30; run \`node $RUN --gate\` yourself for an immediate check)."
  exit 0
fi

# Run the gate (cheap model, isolated, recursion-guarded).
#
# BOUNDED (2026-08-14): this opt-in path still had the unbounded sweep the
# deferral above was created to avoid — 18 tasks x 300 s, worst case hours, run
# inside stop-checks.sh's 480 s ceiling, and reached LAST, after verify + soft
# tests + review have already spent most of it. Killed mid-sweep it leaves a
# truncated results/latest.json behind, which the next reader treats as a
# verdict. --budget-sec stops STARTING tasks that cannot finish and marks the
# run `partial`, so a cut-short sweep is labelled instead of silently believed.
# Default 120 s ≈ what stage 3 can actually expect to have left.
SERGE_GATE_ACTIVE=1 SERGE_EVAL_MODEL="${SERGE_GATE_MODEL:-qwen-coder}" \
  node "$RUN" --gate --budget-sec "${SERGE_GATE_INLINE_BUDGET:-120}" >/dev/null 2>&1
printf '%s' "$now_hash" > "$HASHF" 2>/dev/null || true   # this state is now assessed; don't re-gate it
touch "$EVALS/.last-gate" 2>/dev/null || true

[ -f "$LATEST" ] || exit 0

# Classify baseline→latest: genuine regression vs infra error vs improvement.
eval "$(python3 -c '
import sys, json, shlex
try:
    base=json.load(open(sys.argv[1])); latest=json.load(open(sys.argv[2]))
except Exception:
    print("GATE_GENUINE_N=0"); sys.exit(0)
bp={r["id"]: r.get("pass") for r in base.get("results",[])}
genuine=[]; infra=[]; improved=[]
for r in latest.get("results",[]):
    i=r.get("id"); was=bp.get(i); now=r.get("pass")
    if was and not now:
        if r.get("error") or (r.get("run",{}) or {}).get("timedOut"): infra.append(i)
        else: genuine.append(i)
    elif (was is False) and now:
        improved.append(i)
print("GATE_GENUINE="+shlex.quote(" ".join(genuine)))
print("GATE_GENUINE_N="+str(len(genuine)))
print("GATE_INFRA="+shlex.quote(" ".join(infra)))
print("GATE_INFRA_N="+str(len(infra)))
print("GATE_IMPROVED="+shlex.quote(" ".join(improved)))
' "$BASE" "$LATEST" 2>/dev/null)" || exit 0

if [ "${GATE_GENUINE_N:-0}" -gt 0 ]; then
  msg="serge-eval ⚠ POST-EDIT regression in [${GATE_GENUINE}] — your change to a behavior-defining file made these fail (they passed on baseline). Fix it, or accept the new behavior with \`node $RUN --update-baseline\`."
  if [ "${SERGE_GATE_ENFORCE:-0}" = "1" ]; then
    printf '%s\n' "$msg Stop blocked (SERGE_GATE_ENFORCE=1) — resolve before ending the turn." >&2
    exit 2
  fi
  emit_msg "$msg (advisory; set SERGE_GATE_ENFORCE=1 to block)."
  exit 0
fi

if [ "${GATE_INFRA_N:-0}" -gt 0 ]; then
  emit_msg "serge-eval: post-edit gate could not verify [${GATE_INFRA}] (provider/router error, not a regression)."
  exit 0
fi

if [ -n "${GATE_IMPROVED:-}" ]; then
  emit_msg "serge-eval ✓ post-edit gate green (improved: [${GATE_IMPROVED}]) — consider \`node $RUN --update-baseline\`."
  exit 0
fi

exit 0   # green, nothing notable
