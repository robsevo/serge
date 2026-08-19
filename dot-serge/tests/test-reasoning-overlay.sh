#!/usr/bin/env bash
# Tests for reasoning-overlay.sh — $0, no LLM. deliberate.md was inert before this
# hook existed (only referenced from a comment in logic-directive.sh), so the
# central assertion is that its content actually reaches a session now.
set -uo pipefail
HOOK="${SERGE_REASONING_OVERLAY_SCRIPT:-$HOME/.serge/reasoning-overlay.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

ctx() { python3 -c '
import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: pass'; }

start() { python3 -c 'import json;print(json.dumps({"hook_event_name":"SessionStart","cwd":"/tmp"}))' 2>/dev/null | bash "$HOOK"; }
turn()  { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"UserPromptSubmit","prompt":sys.argv[1],"cwd":"/tmp"}))' "$1" 2>/dev/null | bash "$HOOK"; }

# 1. session start carries the actual method file
out=$(start | ctx)
if printf '%s' "$out" | grep -q "CHECK THE OBVIOUS ANSWER" && printf '%s' "$out" | grep -q "GROUND IT"; then
  ok "SessionStart injects deliberate.md (no longer inert)"
else bad "session-start injection missing (out=${out:0:200})"; fi

# 2. the two directives added 2026-07-29 are in it
if printf '%s' "$out" | grep -q "Get the actual answer" && printf '%s' "$out" | grep -q "Make the evidence say it"; then
  ok "independence + evidence sections present"
else bad "new sections missing from the loaded file"; fi

# 3. stubbornness rule specifically
if printf '%s' "$out" | grep -q "Change your mind on new evidence, never on pressure"; then
  ok "hold-your-position rule loaded"
else bad "stubbornness rule missing"; fi

# 4. ordinary turn gets the kernel
out=$(turn "why does the retry path fire twice here?" | ctx)
if printf '%s' "$out" | grep -q "Reasoning kernel" && printf '%s' "$out" | grep -q "first instinct is a draft"; then
  ok "substantive turn → kernel injected"
else bad "kernel missing on a real turn (out=${out:0:200})"; fi

# 5. kernel stays cheap
len=$(printf '%s' "$out" | wc -c)
if [ "$len" -lt 900 ]; then ok "kernel is compact (${len} chars/turn)"
else bad "kernel too fat (${len} chars)"; fi

# 6. "continue" MUST still get it — that is exactly when method matters
out=$(turn "continue")
if [ -n "$out" ]; then ok "'continue' → kernel injected (resumes real work)"
else bad "'continue' treated as an acknowledgement"; fi

# 7. pure acknowledgements skipped
for p in "ok" "thanks!" "yep" "perfect"; do
  out=$(turn "$p")
  if [ -z "$out" ]; then ok "acknowledgement skipped: '$p'"
  else bad "wasted tokens on '$p'"; fi
done

# 8. slash commands carry their own instructions
out=$(turn "/recap")
if [ -z "$out" ]; then ok "slash command skipped"
else bad "fired on a slash command"; fi

# 9. harness plumbing is not a turn
NOTIF='[SYSTEM NOTIFICATION - NOT USER INPUT]
<task-notification><summary>fix the retry path</summary></task-notification>'
out=$(turn "$NOTIF")
if [ -z "$out" ]; then ok "task-notification ignored"
else bad "fired on harness plumbing"; fi

# 10. cost dial keeps session load, drops per-turn kernel
out=$(SERGE_REASONING_KERNEL=0 turn "why does this fire twice?")
out2=$(SERGE_REASONING_KERNEL=0 start)
if [ -z "$out" ] && [ -n "$out2" ]; then ok "SERGE_REASONING_KERNEL=0 → session-only"
else bad "cost dial wrong (turn=${out:0:60} start=${out2:0:40})"; fi

# 11. off-switch
out=$(SERGE_REASONING_OVERLAY_DISABLE=1 start)
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# 12. malformed input → fail open
out=$(printf 'not json' | bash "$HOOK")
if [ -z "$out" ]; then ok "malformed input → fails open"
else bad "malformed input produced output"; fi

echo
echo "reasoning-overlay: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
