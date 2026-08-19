#!/usr/bin/env bash
# Regression tests for the cross-step repeat CEILING in tool-dedupe-guard.sh.
#
# WHY THIS EXISTS (2026-08-15): a user reported `/swarm` running 6 times with
# nothing stopping it. Cause: tool-repeat-guard.sh is PostToolUse, so it can
# only nudge (R1@3, R2@5, R3@8) — it runs after execution and can never refuse.
# tool-dedupe-guard.sh is PreToolUse and CAN refuse, but only saw same-step
# siblings. Cross-step repeats were therefore unstoppable by any hook.
# The ceiling closes that gap by reading the streak the ladder already writes.
#
# The risk this file guards is FALSE POSITIVES: this is a DENY path, so a bug
# here blocks legitimate work. T1/T3/T5 are the ones that matter most — they
# assert the guard stays out of the way.
set -uo pipefail

DEDUPE="${SERGE_DEDUPE_GUARD:-$HOME/.serge/tool-dedupe-guard.sh}"
REPEAT="${SERGE_REPEAT_GUARD:-$HOME/.serge/tool-repeat-guard.sh}"
for f in "$DEDUPE" "$REPEAT"; do
  [ -x "$f" ] || { echo "FATAL: $f missing or not executable"; exit 1; }
done

TMPDIR="$(mktemp -d)"; export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
no(){ fail=$((fail+1)); echo "  FAIL $1 — expected $2, got $3"; }
check(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

# One full Pre -> exec -> Post cycle. Echoes DENY or RUN.
# Mirrors production ordering: PreToolUse decides; only if allowed does the
# tool "run" and the PostToolUse hooks fire (ladder increments, lock clears).
cycle(){
  local sid="$1" cmd="$2" tool="${3:-Bash}"
  local ti pre post
  ti="{\"command\":\"$cmd\"}"
  pre="{\"session_id\":\"$sid\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$tool\",\"tool_use_id\":\"t\",\"transcript_path\":\"/nonexistent\",\"tool_input\":$ti}"
  post="{\"session_id\":\"$sid\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"$tool\",\"tool_input\":$ti,\"tool_response\":{}}"
  if printf '%s' "$pre" | "$DEDUPE" 2>/dev/null | command grep -q '"deny"'; then
    echo DENY; return
  fi
  printf '%s' "$post" | "$REPEAT"  >/dev/null 2>&1   # ladder counts the streak
  printf '%s' "$post" | "$DEDUPE"  >/dev/null 2>&1   # release in-flight lock
  echo RUN
}

echo "test-tool-repeat-ceiling.sh"

# T1 — the false-positive guard. Any different call resets the ladder, so a
# long-but-interrupted series must never be denied.
r=""
for i in $(seq 1 12); do
  r="$(cycle t1 same.sh)"
  [ $((i % 3)) -eq 0 ] && cycle t1 "other-$i.sh" >/dev/null
done
check "interleaved different calls never deny" RUN "$r"

# T2 — the actual stop. 8 uninterrupted calls run (ladder nudges), 9th denies.
for i in $(seq 1 8); do cycle t2 loop.sh >/dev/null; done
check "9th uninterrupted identical call denies" DENY "$(cycle t2 loop.sh)"

# T3 — polling tools are exempt by design; denying them would break TaskOutput.
r=""; for i in $(seq 1 12); do r="$(cycle t3 x TaskOutput)"; done
check "exempt polling tool never denies" RUN "$r"

# T4 — both off-switches, because a wrong deny must be escapable without a
# code edit. CEILING=0 kills this layer only; DEDUPE_DISABLE=1 kills the hook.
for i in $(seq 1 9); do cycle t4 loop.sh >/dev/null; done
check "SERGE_TOOL_REPEAT_CEILING=0 disables" RUN \
  "$(SERGE_TOOL_REPEAT_CEILING=0 cycle t4 loop.sh)"
check "SERGE_TOOL_DEDUPE_DISABLE=1 disables" RUN \
  "$(SERGE_TOOL_DEDUPE_DISABLE=1 cycle t4 loop.sh)"

# T5 — fail open. No state file (fresh session) and a corrupt one must both
# allow; a guard that denies on unreadable state would brick a session.
rm -f "$TMPDIR"/serge-toolrepeat-*.json
check "missing state file fails open" RUN "$(cycle t5 anything.sh)"
for i in $(seq 1 9); do cycle t5b loop.sh >/dev/null; done
for f in "$TMPDIR"/serge-toolrepeat-*.json; do printf 'not json{' > "$f"; done
check "corrupt state file fails open" RUN "$(cycle t5b loop.sh)"

# T6 — the ladder itself still escalates on schedule (the ceiling reads its
# state, so a change to either side must keep them agreeing).
sid=t6; ti='{"command":"ladder.sh"}'
post="{\"session_id\":\"$sid\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":$ti,\"tool_response\":{}}"
got=""
for i in $(seq 1 8); do
  out="$(printf '%s' "$post" | "$REPEAT" 2>/dev/null)"
  if   [ -z "$out" ];                                        then got="$got-"
  elif printf '%s' "$out" | command grep -q 'final response now';  then got="${got}3"
  elif printf '%s' "$out" | command grep -q 'Choose exactly one';  then got="${got}2"
  else                                                            got="${got}1"
  fi
done
check "ladder fires --11222 3 across 8 calls" "--11222 3" "${got:0:7} ${got:7:1}"

echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
