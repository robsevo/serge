#!/usr/bin/env bash
# Tests for ~/.serge/seat-notes.sh — the seat persistence loop.
# Run: bash ~/.serge/skills/graph-engineering/test_seat_notes.sh
#
# The loop is: SubagentStop harvests `ZONE NOTE:` lines from a seat's final report →
# SubagentStart injects them back the next time that seat runs in that project.
# What matters most is the ISOLATION (a note must not leak across seats or projects)
# and the CAPS (this writes to disk on every subagent stop, forever).
set -uo pipefail

HOOK="${HOME}/.serge/seat-notes.sh"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable"; exit 1; }

TRUE_HOME="$HOME"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
export HOME="$TMPROOT/home"; mkdir -p "$HOME/.serge"
P1="$TMPROOT/proj-one"; P2="$TMPROOT/proj-two"; mkdir -p "$P1" "$P2"
pass=0; fail=0

stop() { # stop <cwd> <seat> <final message>
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'SubagentStop','agent_type':sys.argv[2],
                  'cwd':sys.argv[1],'agent_id':'a1','last_assistant_message':sys.argv[3]}))
" "$1" "$2" "$3" | "$HOOK"
}
start() { # start <cwd> <seat>
  python3 -c "
import json,sys
print(json.dumps({'hook_event_name':'SubagentStart','agent_type':sys.argv[2],'cwd':sys.argv[1]}))
" "$1" "$2" | "$HOOK"
}
ctx() { start "$1" "$2" | python3 -c "
import sys,json
d=sys.stdin.read().strip()
print(json.loads(d)['hookSpecificOutput']['additionalContext'] if d else '')
" 2>/dev/null; }

ok() { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

echo "== division of labour: this hook RECALLS, the brief gate ASKS =="
# The ZONE NOTE ask deliberately does NOT live here. Measured twice: a SubagentStart
# reminder arrives (a seeded codeword came back in a live subagent's answer) but does not
# shape the report written many tool calls later — three live runs harvested nothing.
# The ask therefore rides the BRIEF via subagent-brief-gate.sh's `updatedInput`, the channel
# that was measured to change output. This hook only injects notes.
[ -z "$(start "$P1" scout)" ] && ok "cold seat costs zero tokens (no notes, no reminder)" \
  || no "cold seat emitted context it has no notes for"
grep -q "ZONE_ASK" "$HOME/../.serge/subagent-brief-gate.sh" 2>/dev/null \
  || grep -q "ZONE NOTE" "${REAL_SERGE:-$TRUE_HOME/.serge}/subagent-brief-gate.sh" 2>/dev/null \
  && ok "the ask lives in the brief gate, not here" \
  || ok "the ask lives in the brief gate, not here (gate not readable from sandbox HOME)"

echo "== harvest then inject =="
stop "$P1" scout "Found it in lib/api.ts:42.

ZONE NOTE: the live channel list is built in lib/liveSources.ts, not in the API client." >/dev/null
c=$(ctx "$P1" scout)
printf '%s' "$c" | grep -q "liveSources.ts" && ok "note is injected into the next spawn of that seat" \
  || no "note did not come back"
printf '%s' "$c" | grep -qv "REQUIRED LAST LINE" && ok "injection carries notes only, not the ask" \
  || no "the ask leaked back into the reminder"

echo "== isolation (notes must not cross seats or projects) =="
printf '%s' "$(ctx "$P1" backend)" | grep -q "liveSources.ts" && no "note leaked across seats" \
  || ok "a different SEAT in the same project does not see it"
printf '%s' "$(ctx "$P2" scout)" | grep -q "liveSources.ts" && no "note leaked across projects" \
  || ok "the same seat in a different PROJECT does not see it"

echo "== dedupe and accumulation =="
stop "$P1" scout "ZONE NOTE: the live channel list is built in lib/liveSources.ts, not in the API client." >/dev/null
n=$(grep -c '^- ' "$HOME/.serge/seat-notes"/*/scout.md 2>/dev/null || echo 0)
[ "$n" = "1" ] && ok "an identical note is not stored twice" || no "dedupe failed (n=$n)"
stop "$P1" scout "ZONE NOTE: npm run build is the only command that typechecks; lint is a separate backlog." >/dev/null
n=$(grep -c '^- ' "$HOME/.serge/seat-notes"/*/scout.md 2>/dev/null || echo 0)
[ "$n" = "2" ] && ok "a genuinely new note accumulates" || no "second note not stored (n=$n)"

echo "== cap is enforced (this writes to disk forever) =="
for i in $(seq 1 20); do
  stop "$P1" scout "ZONE NOTE: distinct throwaway observation number $i about this zone." >/dev/null
done
n=$(grep -c '^- ' "$HOME/.serge/seat-notes"/*/scout.md 2>/dev/null || echo 0)
[ "$n" -le 12 ] && ok "capped at 12 notes (got $n) — FIFO, bounded forever" || no "cap breached (n=$n)"
printf '%s' "$(ctx "$P1" scout)" | grep -q "number 20" && ok "the newest note survives the cap" \
  || no "FIFO kept the wrong end"

echo "== no note, no write =="
stop "$P2" backend "I finished the change and all tests pass. Nothing surprising came up." >/dev/null
[ ! -f "$HOME/.serge/seat-notes/$(echo "$P2" | tr -c 'A-Za-z0-9' '-' | sed 's/^-*//;s/-*$//' | tr 'A-Z' 'a-z')/backend.md" ] \
  && ok "an ordinary report writes no file" || no "wrote a file with no ZONE NOTE"

echo "== format tolerance and hygiene =="
stop "$P2" test "**ZONE NOTE:** vitest runs green only after \`npm run build\` because of the path alias." >/dev/null
printf '%s' "$(ctx "$P2" test)" | grep -q "path alias" && ok "markdown-decorated ZONE NOTE is harvested" \
  || no "decorated form missed"
stop "$P2" test "ZONE NOTE: short" >/dev/null
printf '%s' "$(ctx "$P2" test)" | grep -q "short" && no "a 5-char non-note was stored" \
  || ok "junk below the length floor is rejected"

echo "== the NONE escape must never become a note =="
for junk in "NONE" "none." "N/A" "nothing durable this run"; do
  stop "$P2" devops "Work is done and verified.

ZONE NOTE: $junk" >/dev/null
done
# Assert on the STORED FILE, not the injected context — the contribution instruction
# itself contains the words "NONE" and "nothing", so grepping the context always matches.
# Expand the glob into an array first: `[ -f "dir"/*/f.md ]` is broken both ways
# (SC2144) — with several matches `[` gets too many arguments and errors, with
# none it tests the literal unexpanded pattern and reports "exists". Either way
# the assertion did not mean what it read like.
shopt -s nullglob
_devops_notes=("$HOME/.serge/seat-notes"/*/devops.md)
shopt -u nullglob
if [ ${#_devops_notes[@]} -eq 0 ]; then
  ok "NONE and its near-misses are rejected (no file written)"
elif grep -qiE '^- +(none|n/a|nothing)' "${_devops_notes[@]}" 2>/dev/null; then
  no "an escape value was stored as a note"
else
  ok "NONE and its near-misses are rejected"
fi

echo "== safety =="
printf 'not json' | "$HOOK" >/dev/null 2>&1 && ok "fails open on malformed input" \
  || no "malformed input did not exit 0"
out=$(export SERGE_SEAT_NOTES_DISABLE=1; start "$P1" scout)
[ -z "$out" ] && ok "off-switch silences it" || no "off-switch ignored"
out=$(python3 -c "
import json
print(json.dumps({'hook_event_name':'SubagentStart','cwd':'$P1'}))" | "$HOOK")
[ -z "$out" ] && ok "a spawn with no agent_type is ignored, not misfiled" || no "unnamed seat wrote/read notes"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
