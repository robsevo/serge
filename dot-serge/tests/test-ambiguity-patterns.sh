#!/usr/bin/env bash
# A.3 pattern tests for ambiguity-directive.sh — $0, no LLM. Verifies the new
# G4 (fresh-start scope-bomb) and G5 (bare failure report) classes fire with
# their specific directive lines, the original G1/G2/G3 classes still fire
# (non-regression), and fully-specified prompts stay quiet.
set -uo pipefail
HOOK="${SERGE_AMBIGUITY_SCRIPT:-$HOME/.serge/ambiguity-directive.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

run() { printf '{"prompt":%s}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" | bash "$HOOK"; }

# 1. G4 fresh-start fires with the blast-radius line
out=$(run "this is a mess, let's just start over from scratch")
if printf '%s' "$out" | grep -q "FRESH-START SCOPE"; then ok "G4 fresh-start → blast-radius directive"
else bad "G4 missed (out=${out:0:120})"; fi

# 2. G5 bare failure fires with the reproduce-first line
out=$(run "the page is still not working after your change")
if printf '%s' "$out" | grep -q "BARE FAILURE REPORT"; then ok "G5 bare-failure → reproduce-first directive"
else bad "G5 missed (out=${out:0:120})"; fi

# 3. G5 variant: "nothing happens"
out=$(run "I click the button and nothing happens")
if printf '%s' "$out" | grep -q "BARE FAILURE REPORT"; then ok "G5 'nothing happens' variant fires"
else bad "G5 variant missed"; fi

# 4. non-regression: G2 irreversible-vague still fires (without G4/G5 lines)
out=$(run "delete the old config we're not using")
if printf '%s' "$out" | grep -q "IRREVERSIBLE" && ! printf '%s' "$out" | grep -q "FRESH-START"; then
  ok "G2 still fires, no spurious G4/G5 lines"
else bad "G2 regression (out=${out:0:120})"; fi

# 5. non-regression: G1 vague action still fires
out=$(run "clean this up please")
if printf '%s' "$out" | grep -q "underspecified"; then ok "G1 still fires"
else bad "G1 regression"; fi

# 6. fully-specified prompt stays quiet
out=$(run "In src/app.py line 40, change the timeout argument from 30 to 60")
if [ -z "$out" ]; then ok "fully-specified prompt → quiet"
else bad "false positive on specified prompt (out=${out:0:120})"; fi

# 7. specific failure report with named error stays quiet (not a bare report)
out=$(run "pytest fails with ImportError: no module named requests in tests/test_api.py")
if [ -z "$out" ]; then ok "named-error failure report → quiet"
else bad "false positive on named error (out=${out:0:120})"; fi

# 8. off-switch
out=$(SERGE_AMBIGUITY_DIRECTIVE_DISABLE=1 run "start over from scratch")
if [ -z "$out" ]; then ok "off-switch respected"
else bad "off-switch ignored"; fi

# --- G6 (2026-07-22): unnamed referent / unstated baseline -------------------
# The class the user reported as "does something else from memory or assuming".
# It reads specific, so G1-G5 all no-op on it; the model then fills the missing
# referent from the session-loaded memory index instead of from current state.

# 9. comparative with no baseline fires with the G6 line
out=$(run "use the cheaper one instead")
if printf '%s' "$out" | grep -q "UNNAMED REFERENT"; then ok "G6 comparative-no-baseline → unnamed-referent directive"
else bad "G6 comparative missed (out=${out:0:120})"; fi

# 10. change-verb + bare category noun
out=$(run "swap the model")
if printf '%s' "$out" | grep -q "UNNAMED REFERENT"; then ok "G6 bare category noun fires"
else bad "G6 bare-slot missed (out=${out:0:120})"; fi

# 11. unnamed destination behind a preposition
out=$(run "put the reviewer on the free seat")
if printf '%s' "$out" | grep -q "UNNAMED REFERENT"; then ok "G6 prepositional destination fires"
else bad "G6 prepositional missed (out=${out:0:120})"; fi

# 12. comparative applied to a named target
out=$(run "make the watchdog stricter")
if printf '%s' "$out" | grep -q "UNNAMED REFERENT"; then ok "G6 unstated-comparative-baseline fires"
else bad "G6 comparative-target missed (out=${out:0:120})"; fi

# 13. PRECISION: an exact seat name means the request IS specified → quiet.
# This suppressor is what keeps G6 off ordinary work; without it G6 would fire
# on most engineering sentences and become noise.
out=$(run "swap haiku-paid for qwen3-coder-next")
if [ -z "$out" ]; then ok "G6 quiet when the target is named exactly"
else bad "G6 false positive on named seats (out=${out:0:120})"; fi

# 14. PRECISION: ALL_CAPS constant / explicit value
out=$(run "set SERGE_DAILY_CAP_USD to 1")
if [ -z "$out" ]; then ok "G6 quiet on a named constant + value"
else bad "G6 false positive on named constant (out=${out:0:120})"; fi

# 15. PRECISION: a path names the target
out=$(run "change the model in ~/.serge/litellm.yaml to qwen")
if [ -z "$out" ]; then ok "G6 quiet when a path names the target"
else bad "G6 false positive on a path (out=${out:0:120})"; fi

# 16. PRECISION: ordinary specified work must not trip the new patterns
out=$(run "run the tests for the budget watchdog")
if [ -z "$out" ]; then ok "G6 quiet on ordinary specified work"
else bad "G6 false positive on ordinary work (out=${out:0:120})"; fi

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — ambiguity patterns trustworthy"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
