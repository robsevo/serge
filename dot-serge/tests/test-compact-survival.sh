#!/usr/bin/env bash
# Tests for compact-survival.sh — $0, no LLM. Builds a synthetic transcript in the
# real JSONL shape, captures at PreCompact, then re-injects at SessionStart.
set -uo pipefail
HOOK="${SERGE_COMPACT_SURVIVAL_SCRIPT:-$HOME/.serge/compact-survival.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"; rm -f "$HOME/.serge/cache/compact-survival-"*' EXIT
REAL="$WS/src/real.ts"; mkdir -p "$WS/src"; printf 'export const a=1\n' > "$REAL"
GONE="$WS/src/deleted.ts"   # referenced in the transcript but never created
TX="$WS/transcript.jsonl"
SID="compact-test-$$"

# Transcript: two Read/Edit calls (one path exists, one doesn't), a PASSING test
# command, and a FAILING one that must not be recommended.
python3 - "$TX" "$REAL" "$GONE" <<'PY'
import json,sys
tx,real,gone=sys.argv[1],sys.argv[2],sys.argv[3]
rows=[
 {"type":"assistant","message":{"role":"assistant","content":[
   {"type":"tool_use","id":"t1","name":"Read","input":{"file_path":real}},
   {"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":gone}}]}},
 {"type":"user","message":{"role":"user","content":[
   {"type":"tool_result","tool_use_id":"t1","content":"ok"},
   {"type":"tool_result","tool_use_id":"t2","content":"ok"}]}},
 {"type":"assistant","message":{"role":"assistant","content":[
   {"type":"tool_use","id":"t3","name":"Bash","input":{"command":"bun test src/real.test.ts"}},
   {"type":"tool_use","id":"t4","name":"Bash","input":{"command":"pytest tests/broken.py"}},
   {"type":"tool_use","id":"t5","name":"Bash","input":{"command":"ls -la /tmp"}}]}},
 {"type":"user","message":{"role":"user","content":[
   {"type":"tool_result","tool_use_id":"t3","content":"4 pass"},
   {"type":"tool_result","tool_use_id":"t4","content":"boom","is_error":True},
   {"type":"tool_result","tool_use_id":"t5","content":"files"}]}},
]
open(tx,"w").write("\n".join(json.dumps(r) for r in rows)+"\n")
PY

pre()  { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"PreCompact","session_id":sys.argv[1],
 "transcript_path":sys.argv[2],"cwd":sys.argv[3],"trigger":sys.argv[4],
 "custom_instructions":None}))' "$SID" "$TX" "$WS" "${1:-auto}" 2>/dev/null | bash "$HOOK"; }
post() { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"SessionStart","session_id":sys.argv[1],
 "cwd":sys.argv[2],"source":"compact"}))' "$SID" "$WS" 2>/dev/null | bash "$HOOK"; }
ctx()  { python3 -c '
import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: pass' 2>/dev/null; }

# 1. PreCompact stdout must be a SHORT instruction — it becomes the compaction's
#    custom instructions AND is echoed to the user, so a data dump would spam them.
out=$(pre auto)
if [ -n "$out" ] && [ "$(printf '%s' "$out" | wc -c)" -lt 400 ] \
   && ! printf '%s' "$out" | grep -q "$WS"; then
  ok "PreCompact stdout is a short instruction, not the payload"
else bad "stdout wrong (len=$(printf '%s' "$out" | wc -c)) out=${out:0:120}"; fi

# 2. the snapshot file was written
snapshot=$(ls "$HOME/.serge/cache/compact-survival-"* 2>/dev/null | head -1)
if [ -n "$snapshot" ]; then ok "snapshot file written to cache"
else bad "no snapshot file"; fi

# 3. re-inject carries the verified path, and NOT the vanished one
out=$(post | ctx)
if printf '%s' "$out" | grep -q "src/real.ts" && ! printf '%s' "$out" | grep -q "deleted.ts"; then
  ok "re-inject keeps existing paths, drops ones no longer on disk"
else bad "path filtering wrong (out=${out:0:250})"; fi

# 4. passing command kept, failing command dropped, noise ignored
if printf '%s' "$out" | grep -q "bun test src/real.test.ts" \
   && ! printf '%s' "$out" | grep -q "pytest tests/broken.py" \
   && ! printf '%s' "$out" | grep -q "ls -la"; then
  ok "only verify commands that exited 0 survive"
else bad "command filtering wrong (out=${out:0:250})"; fi

# 5. it says the facts are verified rather than remembered
if printf '%s' "$out" | grep -q "verified, not recalled"; then
  ok "framing tells the model to trust these over memory"
else bad "missing framing"; fi

# 6. the snapshot is CONSUMED — a stale one must never resurface later
out2=$(post)
if [ -z "$out2" ]; then ok "snapshot consumed on inject (no resurfacing)"
else bad "re-injected a consumed snapshot"; fi

# 7. manual trigger works the same way
pre manual >/dev/null
if ls "$HOME/.serge/cache/compact-survival-"* >/dev/null 2>&1; then
  ok "manual trigger also captures"
else bad "manual trigger did not capture"; fi
rm -f "$HOME/.serge/cache/compact-survival-"*

# 8. nothing worth saving → silent (no empty snapshot, no user-facing line)
EMPTY="$WS/empty.jsonl"; printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}\n' > "$EMPTY"
out=$(python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"PreCompact","session_id":"empty-'$$'",
 "transcript_path":sys.argv[1],"cwd":sys.argv[2],"trigger":"auto","custom_instructions":None}))' "$EMPTY" "$WS" 2>/dev/null | bash "$HOOK")
if [ -z "$out" ]; then ok "no verified facts → silent"
else bad "emitted for an empty transcript"; fi

# 9. missing transcript → fail open
out=$(python3 -c '
import json
print(json.dumps({"hook_event_name":"PreCompact","session_id":"nope","transcript_path":"/nonexistent/x.jsonl","cwd":"/tmp","trigger":"auto","custom_instructions":None}))' | bash "$HOOK")
if [ -z "$out" ]; then ok "missing transcript → fails open"
else bad "did not fail open"; fi

# 10. unrelated event → silent
out=$(python3 -c 'import json;print(json.dumps({"hook_event_name":"PostCompact","session_id":"x","cwd":"/tmp"}))' | bash "$HOOK")
if [ -z "$out" ]; then ok "PostCompact (cannot inject) → silent"
else bad "responded to an event it cannot serve"; fi

# 11. off-switch
out=$(SERGE_COMPACT_SURVIVAL_DISABLE=1 pre auto)
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# 12. malformed input → fail open
out=$(printf 'not json' | bash "$HOOK")
if [ -z "$out" ]; then ok "malformed input → fails open"
else bad "malformed input produced output"; fi

echo
echo "compact-survival: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
