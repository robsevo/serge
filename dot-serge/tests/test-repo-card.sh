#!/usr/bin/env bash
# Tests for repo-card.sh — $0, no LLM. The layout fact ("top-level dirs") is the
# one that makes an invented top-level path obviously wrong, so it is asserted
# against a fixture shaped like ~/programs/osimage, where the failure happened.
set -uo pipefail
HOOK="${SERGE_REPO_CARD_SCRIPT:-$HOME/.serge/repo-card.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/archiso_profile/airootfs/root" "$WS/tests" "$WS/node_modules/junk"
printf 'x\n' > "$WS/archiso_profile/airootfs/root/customize_airootfs.sh"
printf 'x\n' > "$WS/tests/test_amnesia.sh"
for i in $(seq 1 30); do printf 'x\n' > "$WS/node_modules/junk/f$i.js"; done
printf '# Privacy OS: Cyberpunk Edition\n' > "$WS/README.md"
printf 'API_KEY=\n# DB_URL=\n' > "$WS/.env.example"
printf '#!/bin/bash\n' > "$WS/build-usb.sh"; chmod +x "$WS/build-usb.sh"

card() { python3 -c '
import json,sys
print(json.dumps({"hook_event_name":"SessionStart","cwd":sys.argv[1]}))' "$1" 2>/dev/null \
  | bash "$HOOK" | python3 -c '
import json,sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception: pass' 2>/dev/null; }

out=$(card "$WS")

# 1. the anti-phantom-path fact
if printf '%s' "$out" | grep -q "top-level dirs:" && printf '%s' "$out" | grep -q "archiso_profile/ (1)"; then
  ok "top-level layout with file counts"
else bad "layout missing (out=${out:0:300})"; fi

# 2. build junk must not be counted or listed
if ! printf '%s' "$out" | grep -q "node_modules"; then ok "node_modules excluded from layout"
else bad "node_modules leaked into the card"; fi

# 3. identity from README when there's no package.json
if printf '%s' "$out" | grep -q "Privacy OS: Cyberpunk Edition"; then ok "identity from README heading"
else bad "identity missing"; fi

# 4. config templates with key counts (commented keys included)
if printf '%s' "$out" | grep -q "\.env\.example (2 keys)"; then ok "config template + commented-key count"
else bad "template/key count wrong (out=${out:0:300})"; fi

# 5. manifest-less project → top-level executable is the entry point
if printf '%s' "$out" | grep -q "entry points: build-usb.sh"; then ok "shell project → executable entry point"
else bad "entry point fallback missed"; fi

# 6. non-repo stated as such, not assumed
if printf '%s' "$out" | grep -q "NOT a git repository"; then ok "git absence stated explicitly"
else bad "git status missing"; fi

# 7. budget
len=$(printf '%s' "$out" | wc -c)
if [ "$len" -lt 1200 ]; then ok "card within budget (${len} chars)"
else bad "card too large (${len} chars)"; fi

# 8. cache is used on the second call (and matches)
out2=$(card "$WS")
if [ "$out" = "$out2" ]; then ok "second call served identically (cache)"
else bad "cache produced a different card"; fi

# 9. cache invalidates when a manifest changes
printf '{"name":"fixture","scripts":{"test":"echo hi"}}' > "$WS/package.json"
out3=$(card "$WS")
if printf '%s' "$out3" | grep -q "declared scripts: test="; then ok "manifest change invalidates cache"
else bad "stale cache after manifest change (out=${out3:0:200})"; fi

# 10. declared commands are reported, never executed
if printf '%s' "$out3" | grep -q "npm run test\|bun run test"; then ok "test command reported from manifest"
else bad "test command not reported"; fi

# 11. $HOME is not a project → quiet
out=$(card "$HOME")
if [ -z "$out" ]; then ok "\$HOME → quiet (not a project)"
else bad "fired on \$HOME"; fi

# 12. off-switch
out=$(SERGE_REPO_CARD_DISABLE=1 card "$WS")
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# 13. no stdin at all (SessionStart may pass nothing) → still works
out=$(cd "$WS" && bash "$HOOK" </dev/null | head -c 80)
if [ -n "$out" ]; then ok "empty stdin → falls back to cwd"
else bad "empty stdin produced nothing"; fi

# --- 2026-07-30: three-event wiring (SessionStart / SubagentStart / cwd drift) ---
# A card emitted once at session start silently describes the WRONG repo as soon
# as the session changes project, and subagents (scout sets omitClaudeMd: true)
# started with no project context at all.
WS2="$(mktemp -d)"; mkdir -p "$WS2/lib"
printf 'y\n' > "$WS2/lib/b.py"; printf '# Other Project\n' > "$WS2/README.md"
ev() { # ev <event> <cwd> <session> [agent_id]
  python3 -c '
import json,sys
d={"hook_event_name":sys.argv[1],"cwd":sys.argv[2],"session_id":sys.argv[3]}
if len(sys.argv)>4: d["agent_id"]=sys.argv[4]; d["agent_type"]="scout"
print(json.dumps(d))' "$@" 2>/dev/null | bash "$HOOK"
}
SID="repocard-events-$$"

ev SessionStart "$WS" "$SID" >/dev/null   # seed the session's "last root"

out=$(ev UserPromptSubmit "$WS" "$SID")
if [ -z "$out" ]; then ok "UserPromptSubmit, same project → silent (zero per-turn cost)"
else bad "re-emitted the card on an ordinary turn"; fi

out=$(ev UserPromptSubmit "$WS2" "$SID")
if printf '%s' "$out" | grep -q "working directory changed project" \
   && printf '%s' "$out" | grep -q "Other Project"; then
  ok "project changed mid-session → fresh card + stale-paths warning"
else bad "cwd drift not handled (out=${out:0:200})"; fi

out=$(ev UserPromptSubmit "$WS2" "$SID")
if [ -z "$out" ]; then ok "settled in the new project → silent again"
else bad "kept re-emitting after the move"; fi

out=$(ev SubagentStart "$WS" "$SID" "agent-xyz")
if printf '%s' "$out" | grep -q "SubagentStart" \
   && printf '%s' "$out" | grep -q "You are a subagent" \
   && printf '%s' "$out" | grep -q "top-level dirs:"; then
  ok "SubagentStart → card + cold-start framing, correct hookEventName"
else bad "subagent grounding missing (out=${out:0:200})"; fi

# CwdChanged cannot inject additionalContext in this fork (hooks.ts:805-845 lists
# the seven events that can) — so the hook must stay silent rather than emit
# output the harness will discard.
out=$(ev CwdChanged "$WS2" "$SID")
if [ -z "$out" ]; then ok "unsupported event (CwdChanged) → silent"
else bad "emitted for an event that cannot inject context"; fi

rm -rf "$WS2"; rm -f "${TMPDIR:-/tmp}"/serge-repocard-*"$$"* 2>/dev/null

echo
echo "repo-card: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
