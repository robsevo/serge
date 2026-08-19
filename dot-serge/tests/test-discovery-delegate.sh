#!/usr/bin/env bash
# Tests for discovery-delegate.sh — $0, no LLM. Case 1 is the literal opening
# prompt of, which scout should have served and didn't.
set -uo pipefail
HOOK="${SERGE_DISCOVERY_DELEGATE_SCRIPT:-$HOME/.serge/discovery-delegate.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

BIG="$(mktemp -d)"; SMALL="$(mktemp -d)"
trap 'rm -rf "$BIG" "$SMALL"' EXIT
for d in a b c d e f g h i j; do
  mkdir -p "$BIG/$d"
  for i in $(seq 1 30); do printf 'x\n' > "$BIG/$d/f$i.ts"; done
done
mkdir -p "$SMALL/src"; printf 'x\n' > "$SMALL/src/main.ts"

run() { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"UserPromptSubmit","prompt":sys.argv[1],"cwd":sys.argv[2]}))
' "$1" "${2:-$BIG}" 2>/dev/null | bash "$HOOK"; }

# 1. the real prompt that burned 25 serial reads
out=$(run "Verify the entire codebase. make sure everything is there. works and is accounted for please")
if printf '%s' "$out" | grep -q 'subagent_type' && printf '%s' "$out" | grep -q 'scout'; then
  ok "'verify the entire codebase' in a big repo → scout offered"
else bad "primary trigger missed (out=${out:0:200})"; fi

# 2. the directive must demand file:line refs (verifiable without re-reading)
if printf '%s' "$out" | grep -q "file:line"; then ok "directive requires file:line refs"
else bad "no file:line requirement"; fi

# 3. and must keep decisions with the main agent
if printf '%s' "$out" | grep -q "scout locates, it does not decide"; then
  ok "directive keeps reasoning/editing local"
else bad "missing the locates-not-decides boundary"; fi

# 4. other broad shapes fire
for p in "explain the architecture of this thing" \
         "where is the retry logic implemented" \
         "find all the callers of this helper" \
         "trace how a request flows through"; do
  out=$(run "$p")
  if [ -n "$out" ]; then ok "broad ask fires: ${p:0:34}…"
  else bad "broad ask missed: $p"; fi
done

# 5. small repo → delegation is overhead, stay quiet
out=$(run "explain the architecture of this thing" "$SMALL")
if [ -z "$out" ]; then ok "small repo → quiet (reading directly is correct)"
else bad "fired on a small repo"; fi

# 6. narrow, already-located request → quiet even in a big repo
out=$(run "in src/app.py line 40 change the timeout from 30 to 60")
if [ -z "$out" ]; then ok "narrow located request → quiet"
else bad "false positive on narrow request (out=${out:0:160})"; fi

# 7. harness plumbing is not a user turn (shared contract w/ test-hook-wrappers)
NOTIF='[SYSTEM NOTIFICATION - NOT USER INPUT]
<task-notification><summary>verify the entire codebase</summary></task-notification>'
out=$(run "$NOTIF")
if [ -z "$out" ]; then ok "task-notification ignored"
else bad "fired on harness plumbing"; fi

# 8. off-switch
out=$(SERGE_DISCOVERY_DELEGATE_DISABLE=1 run "verify the entire codebase")
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# 9. malformed input → fail open
out=$(printf 'not json' | bash "$HOOK")
if [ -z "$out" ]; then ok "malformed input → fails open"
else bad "malformed input produced output"; fi

echo
echo "discovery-delegate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
