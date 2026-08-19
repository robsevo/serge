#!/usr/bin/env bash
# Tests for the three gates added 2026-07-30: subagent-refs-gate (SubagentStop),
# task-evidence-gate (TaskCompleted), notify-desk (Notification), plus the
# PostCompact archive half of compact-survival.
set -uo pipefail
SH="${SERGE_HOME:-$HOME/.serge}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }
WS="$(mktemp -d)"; trap 'rm -rf "$WS"; rm -f "${TMPDIR:-/tmp}"/serge-refsgate-* "${TMPDIR:-/tmp}"/serge-taskgate-*' EXIT

# ---------------------------------------------------- subagent refs gate ------
sa() { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"SubagentStop","agent_type":sys.argv[1],
 "agent_id":sys.argv[2],"session_id":"s","last_assistant_message":sys.argv[3]}))' "$@" 2>/dev/null \
 | bash "$SH/subagent-refs-gate.sh"; }

out=$(sa scout a1 "The retry logic is handled in the client module and looks correct.")
if printf '%s' "$out" | grep -q '"block"' && printf '%s' "$out" | grep -q "names no location"; then
  ok "scout answering in prose → blocked"
else bad "prose not blocked (out=${out:0:150})"; fi

out=$(sa scout a2 "Retry lives in src/api/client.ts:88, called from src/api/index.ts.")
if [ -z "$out" ]; then ok "scout citing file:line → allowed"
else bad "blocked a properly cited answer"; fi

out=$(sa scout a3 "I searched src/ and tests/ — no retry logic exists anywhere.")
if [ -z "$out" ]; then ok "honest 'not found' → allowed (never punished)"
else bad "punished a legitimate negative result"; fi

out=$(sa reviewer a4 "This looks fine overall, no concerns.")
if [ -z "$out" ]; then ok "non-discovery agent (reviewer) → untouched"
else bad "gated an agent type it should ignore"; fi

sa scout a5 "vague prose again" >/dev/null
out=$(sa scout a5 "still vague prose")
if [ -z "$out" ]; then ok "block-once: second stop from same agent passes"
else bad "would deadlock the subagent"; fi

out=$(SERGE_SUBAGENT_REFS_DISABLE=1 sa scout a6 "prose")
if [ -z "$out" ]; then ok "refs gate off-switch respected"; else bad "off-switch ignored"; fi

# ---------------------------------------------------- task evidence gate ------
TX="$WS/tx.jsonl"
mk_tx() { # mk_tx <cmd> <is_error>
python3 - "$TX" "$1" "$2" <<'PY'
import json,sys
tx,cmd,err=sys.argv[1],sys.argv[2],sys.argv[3]=="1"
rows=[{"type":"assistant","message":{"role":"assistant","content":[
        {"type":"tool_use","id":"b1","name":"Bash","input":{"command":cmd}}]}},
      {"type":"user","message":{"role":"user","content":[
        {"type":"tool_result","tool_use_id":"b1","content":"out","is_error":err}]}}]
open(tx,"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY
}
tc() { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"TaskCompleted","task_id":sys.argv[1],
 "task_subject":sys.argv[2],"transcript_path":sys.argv[3],"session_id":"s"}))' "$@" 2>/dev/null \
 | bash "$SH/task-evidence-gate.sh"; }

mk_tx "bun test tests/foo.test.ts" 0
out=$(tc t1 "Fix the parser and test it" "$TX")
if [ -z "$out" ]; then ok "task wanting tests + passing test → allowed"
else bad "blocked despite passing evidence (out=${out:0:140})"; fi

mk_tx "bun test tests/foo.test.ts" 1
out=$(tc t2 "Fix the parser and test it" "$TX")
if printf '%s' "$out" | grep -q '"block"' && printf '%s' "$out" | grep -q "did not exit 0"; then
  ok "task wanting tests + FAILING test → blocked, names the failure"
else bad "failing test not caught (out=${out:0:160})"; fi

mk_tx "ls -la" 0
out=$(tc t3 "Verify the migration works" "$TX")
if printf '%s' "$out" | grep -q '"block"'; then ok "no verification command at all → blocked"
else bad "allowed completion with zero evidence"; fi

out=$(tc t4 "Rename the config variable" "$TX")
if [ -z "$out" ]; then ok "task not asking for tests → untouched (narrow by design)"
else bad "fired on a task that never mentioned testing"; fi

out=$(tc t3 "Verify the migration works" "$TX")
if [ -z "$out" ]; then ok "block-once: same task_id passes on retry"
else bad "would deadlock task completion"; fi

out=$(tc t7 "test it" "/nonexistent.jsonl")
if [ -z "$out" ]; then ok "no transcript → fails open (can't prove absence)"
else bad "blocked without evidence of absence"; fi

out=$(SERGE_TASK_EVIDENCE_DISABLE=1 tc t8 "test it" "$TX")
if [ -z "$out" ]; then ok "task gate off-switch respected"; else bad "off-switch ignored"; fi

# ---------------------------------------------------------- notify-desk -------
out=$(python3 -c '
import json;print(json.dumps({"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Serge needs permission to run rm","session_id":"s"}))' \
 | bash "$SH/notify-desk.sh" 2>&1)
if [ -z "$out" ]; then ok "notify-desk emits nothing to stdout/stderr (zero token cost)"
else bad "notify-desk wrote output: ${out:0:100}"; fi

out=$(printf 'not json' | bash "$SH/notify-desk.sh" 2>&1)
if [ -z "$out" ]; then ok "notify-desk malformed input → silent"; else bad "notify-desk noisy on bad input"; fi

# ------------------------------------------------------ PostCompact archive ---
LOG="$HOME/.serge/cache/compact-log"
before=$(ls "$LOG" 2>/dev/null | wc -l)
out=$(python3 -c '
import json;print(json.dumps({"hook_event_name":"PostCompact","trigger":"auto","compact_summary":"kept: the plan and the failing test","session_id":"pcarchive"}))' \
 | bash "$SH/compact-survival.sh")
after=$(ls "$LOG" 2>/dev/null | wc -l)
if [ -z "$out" ] && [ "$after" -gt "$before" ]; then
  ok "PostCompact archives compact_summary, prints nothing"
else bad "PostCompact archive failed (out=${out:0:80} before=$before after=$after)"; fi
if ls "$LOG"/*.md >/dev/null 2>&1 && command grep -qr "kept: the plan" "$LOG" 2>/dev/null; then
  ok "archived summary contains the real text"
else bad "archived file missing content"; fi
ls -t "$LOG"/*.md 2>/dev/null | head -1 | xargs -r rm -f

echo
echo "remaining-hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
