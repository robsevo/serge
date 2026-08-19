#!/usr/bin/env bash
# Tests for the F.3 UNTESTED-DONE feature-flow gate in continue-on-unfinished.sh
# (plus non-regression of its neighbors). Synthetic transcripts, no LLM, no
# network. Guard files are isolated via TMPDIR; each case gets its own session.
set -uo pipefail

HOOK="${SERGE_PERSIST_SCRIPT:-$HOME/.serge/continue-on-unfinished.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# build_tx <file> <user_text> <final_text> [blocks...] — blocks are extra
# tool_use JSON fragments placed in an intermediate assistant turn.
build_tx() {
  local f="$1" user="$2" final="$3"; shift 3
  {
    printf '{"type":"user","message":{"content":"%s"}}\n' "$user"
    if [ "$#" -gt 0 ]; then
      local tools=""
      for b in "$@"; do tools="$tools,$b"; done
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}%s]}}\n' "$tools"
    fi
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$final"
  } > "$f"
}

run_hook() {  # $1 = transcript, $2 = session id → stdout
  printf '{"transcript_path":"%s","session_id":"%s"}' "$1" "$2" | bash "$HOOK"
}

EDIT_PY='{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/app/server.py"}}'
EDIT_MD='{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/app/README.md"}}'
READ_MD='{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/app/README.md"}}'
READ_OTHER_MD='{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/app/CONTRIBUTING.md"}}'
BASH_TEST='{"type":"tool_use","name":"Bash","input":{"command":"pytest tests/ -q"}}'
BASH_SCRIPT_TEST='{"type":"tool_use","name":"Bash","input":{"command":"bash ~/.serge/tests/test-budget-watchdog.sh"}}'
BASH_LS='{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}'

# 1. code edit + done-claim + no verify → BLOCK with feature-flow reason
build_tx "$T/t1" "add rate limiting" "I have implemented the rate limiter. All done." "$EDIT_PY" "$BASH_LS"
out=$(run_hook "$T/t1" s1)
if printf '%s' "$out" | grep -q '"decision": "block"' && printf '%s' "$out" | grep -q 'Feature-flow gate'; then
  ok "untested done-claim over code edit → blocked with feature-flow reason"
else bad "untested done-claim not blocked (out=$out)"; fi

# 2. same but a test runner ran → allow
build_tx "$T/t2" "add rate limiting" "I have implemented the rate limiter and tests pass. All done." "$EDIT_PY" "$BASH_TEST"
out=$(run_hook "$T/t2" s2)
if [ -z "$out" ]; then ok "done-claim with pytest run → allowed"
else bad "pytest run still blocked (out=$out)"; fi

# 3. verify via a test-script invocation → allow
build_tx "$T/t3" "fix watchdog" "I have fixed the watchdog. Done." "$EDIT_PY" "$BASH_SCRIPT_TEST"
out=$(run_hook "$T/t3" s3)
if [ -z "$out" ]; then ok "done-claim with test-script run → allowed"
else bad "test-script run still blocked (out=$out)"; fi

# 4. honest disclosure → allow
build_tx "$T/t4" "add rate limiting" "I have implemented the rate limiter, but it is NOT yet tested — the auth path remains unverified." "$EDIT_PY"
out=$(run_hook "$T/t4" s4)
if [ -z "$out" ]; then ok "honest not-yet-tested disclosure → allowed"
else bad "disclosure still blocked (out=$out)"; fi

# 5. docs-only edit + done-claim → BLOCK via check 3b (UNREAD-DOC).
# This case used to assert "allowed", which encoded the defect the user reported
# on 2026-08-15: a README rewrite declared done, thin, and asked for twice.
# Check 3 exempts docs (rightly — "run the tests" is meaningless for prose), so
# 3b covers them with the weakest honest bar instead: you looked at what you made.
build_tx "$T/t5" "update the readme" "I have updated the README. All done." "$EDIT_MD"
out=$(run_hook "$T/t5" s5)
if printf '%s' "$out" | grep -q '"decision": "block"' && printf '%s' "$out" | grep -q 'Doc gate'; then
  ok "doc write + done-claim, never read back → blocked with doc-gate reason"
else bad "unread doc done-claim not blocked (out=$out)"; fi

# 5b. same, but the doc was Read back AFTER writing → allow.
build_tx "$T/t5b" "update the readme" "I have updated the README. All done." "$EDIT_MD" "$READ_MD"
out=$(run_hook "$T/t5b" s5b)
if [ -z "$out" ]; then ok "doc write + read-back → allowed"
else bad "read-back still blocked (out=$out)"; fi

# 5c. honest disclosure passes here too — same doctrine as check 3.
build_tx "$T/t5c" "update the readme" "I have rewritten the README, but the install steps are unverified — I could not run them here." "$EDIT_MD"
out=$(run_hook "$T/t5c" s5c)
if [ -z "$out" ]; then ok "doc write + honest disclosure → allowed"
else bad "doc disclosure blocked (out=$out)"; fi

# 5d. reading the doc BEFORE writing it proves nothing about what the write
# produced, so the write must re-arm the unread state.
build_tx "$T/t5d" "update the readme" "I have updated the README. All done." "$READ_MD" "$EDIT_MD"
out=$(run_hook "$T/t5d" s5d)
if printf '%s' "$out" | grep -q 'Doc gate'; then ok "read-before-write does not count as verification"
else bad "read-before-write wrongly satisfied the gate (out=$out)"; fi

# 5e. a doc turn with no done-claim is a normal stop — the gate must stay quiet.
build_tx "$T/t5e" "update the readme" "Here is what the README now covers, and what I left out." "$EDIT_MD"
out=$(run_hook "$T/t5e" s5e)
if [ -z "$out" ]; then ok "doc write without a done-claim → allowed"
else bad "doc write without done-claim blocked (out=$out)"; fi

# 5f. a Read of a DIFFERENT doc must not satisfy the gate for the one written.
build_tx "$T/t5f" "update the readme" "I have updated the README. All done." "$EDIT_MD" "$READ_OTHER_MD"
out=$(run_hook "$T/t5f" s5f)
if printf '%s' "$out" | grep -q 'Doc gate'; then ok "reading a different doc does not satisfy the gate"
else bad "wrong-file read satisfied the gate (out=$out)"; fi

# ── Check 3c: FABRICATED VERIFICATION ────────────────────────────────────────
# The 2026-08-16 case: asked why example-web's events tab was empty, serge grepped
# once, read four files, then wrote "Verification Steps Taken … Checked the ESPN
# API Directly … verified by the data.events array being empty" — with zero
# network calls. Its conclusion was falsified by one curl (11 MLS events).
# Checks 2/3/3b all miss it: tool calls WERE made, and nothing was edited.
GREP_T='{"type":"tool_use","name":"Grep","input":{"pattern":"espn"}}'
READ_TS='{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/app/route.ts"}}'
CURL_T='{"type":"tool_use","name":"Bash","input":{"command":"curl -s https://site.api.espn.com/x"}}'

build_tx "$T/t7" "why is the events tab empty" "Verification Steps Taken: I checked the ESPN API directly and verified the response events array is empty." "$GREP_T" "$READ_TS"
out=$(run_hook "$T/t7" s7)
if printf '%s' "$out" | grep -q 'Grounding gate'; then
  ok "claims API verification with no network call → blocked"
else bad "fabricated verification not blocked (out=$out)"; fi

build_tx "$T/t8" "why is the events tab empty" "I checked the ESPN API directly and verified the response events array is empty." "$CURL_T"
out=$(run_hook "$T/t8" s8)
if [ -z "$out" ]; then ok "same claim WITH a real curl → allowed"
else bad "real probe still blocked (out=$out)"; fi

build_tx "$T/t9" "why is the events tab empty" "Based on reading the code the API likely returns nothing, but this is unverified — I have not called the endpoint." "$READ_TS"
out=$(run_hook "$T/t9" s9)
if [ -z "$out" ]; then ok "honest 'unverified' disclosure → allowed"
else bad "disclosure blocked (out=$out)"; fi

build_tx "$T/t10" "explain this route" "The route fetches the scoreboard API and returns a response for each league." "$READ_TS"
out=$(run_hook "$T/t10" s10)
if [ -z "$out" ]; then ok "describing code without claiming verification → allowed"
else bad "plain description blocked (out=$out)"; fi

build_tx "$T/t11" "does the config have mls" "I checked the file and verified the MLS entry is present in lib/leagues.ts." "$READ_TS"
out=$(run_hook "$T/t11" s11)
if [ -z "$out" ]; then ok "verifying a LOCAL file with Read → allowed"
else bad "local-file verification blocked (out=$out)"; fi

# ── Check 3d: UNVERIFIED DEPLOY CLAIM ────────────────────────────────────────
# The 2026-08-16 case: "Deployed. Build verified, pushed to deploy branch.
# Vercel auto-deploy will pick it up." — and it was not live. No workflow in that
# repo triggers on a push to `deploy`. 3c cannot catch this: the turn DID run
# Bash (a build and a push), so it looks probed — but both succeed locally while
# production serves the old bundle.
BUILD_PUSH='{"type":"tool_use","name":"Bash","input":{"command":"npm run build && git push origin deploy"}}'
LIVE_CURL='{"type":"tool_use","name":"Bash","input":{"command":"curl -s https://example-web.example.com/api/events"}}'
LOCAL_CURL='{"type":"tool_use","name":"Bash","input":{"command":"curl -s http://localhost:3000/api/events"}}'
GH_RUN='{"type":"tool_use","name":"Bash","input":{"command":"gh workflow run refresh-links.yml -f mode=deploy-only"}}'
EDIT_MW='{"type":"tool_use","name":"Edit","input":{"file_path":"/tmp/app/middleware.ts"}}'

build_tx "$T/t12" "fix the events tab" "Deployed. Build verified, pushed to deploy branch. Vercel auto-deploy will pick it up." "$EDIT_MW" "$BUILD_PUSH"
out=$(run_hook "$T/t12" s12)
if printf '%s' "$out" | grep -q 'Deploy gate'; then ok "build+push claiming Deployed → blocked"
else bad "unverified deploy claim not blocked (out=$out)"; fi

build_tx "$T/t13" "fix the events tab" "Deployed and confirmed live." "$EDIT_MW" "$BUILD_PUSH" "$LIVE_CURL"
out=$(run_hook "$T/t13" s13)
if [ -z "$out" ]; then ok "deploy claim + live URL fetch → allowed"
else bad "live probe still blocked (out=$out)"; fi

build_tx "$T/t14" "deploy it" "Deployed via the release workflow." "$EDIT_MW" "$GH_RUN"
out=$(run_hook "$T/t14" s14)
if [ -z "$out" ]; then ok "deploy claim + real workflow run → allowed"
else bad "workflow run blocked (out=$out)"; fi

# localhost is THIS machine — the exact confusion the gate exists to catch.
build_tx "$T/t15" "fix it" "Deployed. It is now live." "$EDIT_MW" "$BUILD_PUSH" "$LOCAL_CURL"
out=$(run_hook "$T/t15" s15)
if printf '%s' "$out" | grep -q 'Deploy gate'; then ok "localhost curl does NOT count as production"
else bad "localhost accepted as a live probe (out=$out)"; fi

build_tx "$T/t16" "fix it" "Pushed to the deploy branch, but it is NOT yet live — you still need to run the release workflow." "$EDIT_MW" "$BUILD_PUSH"
out=$(run_hook "$T/t16" s16)
if [ -z "$out" ]; then ok "honest 'pushed but not live' disclosure → allowed"
else bad "deploy disclosure blocked (out=$out)"; fi

build_tx "$T/t17" "how does deploy work" "The deployed version reads link data at request time." "$EDIT_MW"
out=$(run_hook "$T/t17" s17)
if [ -z "$out" ]; then ok "describing deployment without claiming one → allowed"
else bad "plain description blocked (out=$out)"; fi

# ── Check 3a: DETERMINISTIC CHECKER — the suite RAN and FAILED ───────────────
# Check 3 originally set verify_ran on the INVOCATION and never read the result,
# so a model could run the suite, watch it fail, claim "All done", and pass the
# gate. "Ran a test" is not the bar; "the test passed" is. These cases need tool
# RESULTS, which build_tx cannot emit, so they build the transcript directly.
# NOTE the case-sensitivity trap: under re.I a bare `FAILED` matches the "failed"
# in "0 failed" and marks a green suite red. Both tallies are asserted below.
tx_result() {  # tx_result <file> <result-body> <is_error> <final-text>
  cat > "$1" <<EOF
{"type":"user","message":{"content":"fix the parser"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"w"},{"type":"tool_use","id":"tu1","name":"Edit","input":{"file_path":"/tmp/app/server.py"}},{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"pytest tests/ -q"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu2","content":"$2","is_error":$3}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"$4"}]}}
EOF
}
chk_result() {  # chk_result <label> <body> <is_error> <final> <block|allow>
  tx_result "$T/r" "$2" "$3" "$4"
  local out; out=$(run_hook "$T/r" "r$RANDOM")
  if [ "$5" = "block" ]; then
    printf '%s' "$out" | grep -q 'checker already' && ok "$1" || bad "$1 — not blocked (out=${out:0:90})"
  else
    [ -z "$out" ] && ok "$1" || bad "$1 — wrongly blocked (out=${out:0:90})"
  fi
}

chk_result "failing suite + done-claim → blocked"  "9 pass, 3 fail"                    false "I have fixed it. All done." block
chk_result "green suite + done-claim → allowed"    "12 pass, 0 fail"                   false "I have fixed it. All done." allow
chk_result "pytest FAILED line → blocked"          "FAILED tests/test_x.py::test_y"    false "I have fixed it. All done." block
chk_result "pytest green → allowed"                "5 passed in 0.4s"                  false "I have fixed it. All done." allow
chk_result "tsc error → blocked"                   "src/x.ts(4,10): error TS2322: bad" false "I have fixed it. All done." block
chk_result "tsc clean → allowed"                   "  "                                false "I have fixed it. All done." allow
chk_result "tool is_error → blocked"               "command not found"                 true  "I have fixed it. All done." block
chk_result "failing but reported honestly"         "9 pass, 3 fail"                    false "3 tests are NOT yet passing — unverified." allow

# 6. anti-loop: identical final text doesn't re-block
out=$(run_hook "$T/t1" s1)
if [ -z "$out" ]; then ok "identical text re-run → not re-blocked (anti-loop)"
else bad "anti-loop guard failed (out=$out)"; fi

# 7. FALSE-DONE neighbor still works: done-claim with zero tools → its block, not F.3's
build_tx "$T/t7" "fix the bug" "I have fixed the bug and everything is working."
out=$(run_hook "$T/t7" s7)
if printf '%s' "$out" | grep -q '"decision": "block"' && printf '%s' "$out" | grep -q 'ZERO'; then
  ok "zero-tool done-claim → FALSE-DONE block (non-regression)"
else bad "FALSE-DONE regressed (out=$out)"; fi

# 8. off-switch
build_tx "$T/t8" "add rate limiting" "I have implemented the rate limiter. All done." "$EDIT_PY"
out=$(SERGE_AUTOCONTINUE_DISABLE=1 run_hook "$T/t8" s8)
if [ -z "$out" ]; then ok "SERGE_AUTOCONTINUE_DISABLE=1 → hook inert"
else bad "off-switch ignored (out=$out)"; fi

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — feature-flow stop gate trustworthy"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
