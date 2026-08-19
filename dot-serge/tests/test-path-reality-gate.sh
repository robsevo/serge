#!/usr/bin/env bash
# Tests for path-reality-gate.sh — $0, no LLM. Fixture mirrors the real failure
# (~/programs/osimage): a phantom `airootfs/root/` tree written
# alongside the real `archiso_profile/airootfs/root/`.
set -uo pipefail
HOOK="${SERGE_PATH_GATE_SCRIPT:-$HOME/.serge/path-reality-gate.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
mkdir -p "$WS/archiso_profile/airootfs/root" \
         "$WS/archiso_profile/airootfs/opt/serge" \
         "$WS/src"
printf '#!/bin/bash\necho hi\n'            > "$WS/archiso_profile/airootfs/root/customize_airootfs.sh"
printf '#!/bin/bash\nrm -rf /var/lib\n'    > "$WS/archiso_profile/airootfs/opt/serge/linkage-cleanup.sh"
printf 'FOO=\nBAR=baz\nBAZ=\n'             > "$WS/.env.example"
printf 'export const x = 1\n'              > "$WS/src/app.ts"

n=0
run() { # run <tool> <file_path> [session_suffix]
  n=$((n+1))
  local sid="pathgate-test-$$-${3:-$n}"
  python3 -c '
import json,sys
print(json.dumps({
  "hook_event_name":"PreToolUse",
  "tool_name":sys.argv[1],
  "tool_input":{"file_path":sys.argv[2]},
  "cwd":sys.argv[3],
  "session_id":sys.argv[4],
}))' "$1" "$2" "$WS" "$sid" 2>/dev/null | bash "$HOOK"
}

# 1. the exact measured failure: Write into a phantom tree whose tail is real
out=$(run Write "$WS/airootfs/root/.env.skel" phantom1)
if printf '%s' "$out" | grep -q '"deny"' && printf '%s' "$out" | grep -q 'archiso_profile/airootfs/root'; then
  ok "B: phantom parent dir → deny naming the real directory"
else bad "B missed (out=${out:0:200})"; fi

# 2. Edit against an invented path when the basename exists for real
out=$(run Edit "$WS/airootfs/root/linkage-cleanup.sh" editghost)
if printf '%s' "$out" | grep -q '"deny"' && printf '%s' "$out" | grep -q 'opt/serge/linkage-cleanup.sh'; then
  ok "A: nonexistent Edit target → deny naming the real file"
else bad "A missed (out=${out:0:200})"; fi

# 3. new env file authored from scratch beside an existing template
out=$(run Write "$WS/.env.local" envfam)
if printf '%s' "$out" | grep -q '"deny"' && printf '%s' "$out" | grep -q '\.env\.example' \
   && printf '%s' "$out" | grep -q '3 keys'; then
  ok "C: new env file → deny naming existing template + key count"
else bad "C missed (out=${out:0:200})"; fi

# 4. block-once: same target twice in one session → second call passes
sid="pathgate-once-$$"
first=$(run Write "$WS/airootfs/root/.env.skel" "once-$$")
second=$(run Write "$WS/airootfs/root/.env.skel" "once-$$")
if printf '%s' "$first" | grep -q '"deny"' && [ -z "$second" ]; then
  ok "block-once: insistence passes on re-issue"
else bad "block-once broken (second=${second:0:120})"; fi

# 5. editing a file that really exists → quiet
out=$(run Edit "$WS/archiso_profile/airootfs/root/customize_airootfs.sh" realedit)
if [ -z "$out" ]; then ok "real Edit target → quiet"
else bad "false positive on real Edit (out=${out:0:160})"; fi

# 6. normal new file in an existing directory → quiet
out=$(run Write "$WS/src/newthing.ts" newfile)
if [ -z "$out" ]; then ok "new file in existing dir → quiet"
else bad "false positive on ordinary Write (out=${out:0:160})"; fi

# 7. genuinely new directory tree, no tail match anywhere → quiet
out=$(run Write "$WS/packages/webhooks/handler.ts" brandnew)
if [ -z "$out" ]; then ok "genuinely new tree → quiet (no nannying)"
else bad "false positive on new tree (out=${out:0:160})"; fi

# 8. target outside the workspace → not our business.
# The path is chosen so it WOULD be denied if the outside-workspace guard were
# removed: its tail `airootfs/root` matches a real directory inside the fixture.
# (The previous version used a path with no tail match anywhere, so it passed
# whether or not the guard existed — verified vacuous by mutation 2026-07-30.)
OUTSIDE="$(mktemp -d)/airootfs/root"
out=$(run Write "$OUTSIDE/probe.txt" outside)
if [ -z "$out" ]; then ok "outside workspace → quiet (even when the tail matches)"
else bad "gated a path outside cwd (out=${out:0:160})"; fi
rm -rf "$(dirname "$(dirname "$OUTSIDE")")" 2>/dev/null

# 9. non-file tool → quiet
out=$(python3 -c '
import json; print(json.dumps({
  "hook_event_name":"PreToolUse","tool_name":"Bash",
  "tool_input":{"command":"ls /nope/nope"},"cwd":"'"$WS"'","session_id":"bash-'$$'"}))' | bash "$HOOK")
if [ -z "$out" ]; then ok "non-mutating tool → quiet"
else bad "gated a non-file tool (out=${out:0:160})"; fi

# 10. off-switch
out=$(SERGE_PATH_GATE_DISABLE=1 run Write "$WS/airootfs/root/.env.skel" offswitch)
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# 11. malformed input → fail open
out=$(printf 'not json' | bash "$HOOK")
if [ -z "$out" ]; then ok "malformed input → fails open"
else bad "malformed input produced output"; fi

rm -f "${TMPDIR:-/tmp}"/serge-pathgate-*"$$"* 2>/dev/null
echo
echo "path-reality-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
