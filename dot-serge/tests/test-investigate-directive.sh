#!/usr/bin/env bash
# Pattern tests for investigate-directive.sh — $0, no LLM, no network.
# Verifies it fires on diagnosis-shaped turns, carries the four anti-guessing
# rules, and stays quiet on build/docs/plain-question turns (a directive on
# every turn is just a token tax).
set -uo pipefail
HOOK="${SERGE_INVESTIGATE_SCRIPT:-$HOME/.serge/investigate-directive.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

run() {
  printf '{"prompt":%s}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | bash "$HOOK"
}
fires() { local out; out=$(run "$2")
  if printf '%s' "$out" | grep -q "INVESTIGATION DISCIPLINE"; then ok "$1"
  else bad "$1 — missed (out=${out:0:100})"; fi; }
quiet() { local out; out=$(run "$2")
  if [ -z "$out" ]; then ok "$1"; else bad "$1 — fired (out=${out:0:100})"; fi; }
has()   { local out; out=$(run "why is the events tab empty")
  if printf '%s' "$out" | grep -q "$2"; then ok "$1"; else bad "$1 — missing '$2'"; fi; }

echo "── fires on diagnosis-shaped turns ──"
# The verbatim prompt from the 2026-08-16 report that motivated this hook.
fires "the real report prompt"  "research deeply and troubleshoot why the events tab in live tv is not working for example-web"
fires "the go-deeper follow-up" "um yesterday there were mls games and it didnt work. go deeper"
fires "why is X empty"          "why is the events list empty"
fires "plain broken"            "the login page is broken"
fires "figure out why"          "figure out why the worker dies at 2am"
fires "not working"             "the events tab is not working"
fires "investigate"             "investigate the stream cutting out"
fires "root cause"              "find the root cause of the 429s"
fires "crashes"                 "the app crashes on startup"
fires "nothing shows"           "nothing shows up in the guide"

echo
echo "── quiet on everything else ──"
quiet "build request"           "add a retry to the fetch helper"
quiet "docs request"            "write a readme for this project"
quiet "plain question"          "what does git bisect do"
quiet "refactor"                "extract this into a helper function"
quiet "slash command"           "/sc:implement retry logic"
quiet "empty prompt"            ""

echo
echo "── the four anti-guessing rules are actually in the payload ──"
has "observe before theorising" "OBSERVE FIRST"
has "falsify your own answer"   "FALSIFY YOUR OWN ANSWER"
has "mark observed vs inferred" "observed or inferred"
has "don't delegate a 5s check" "DELEGATE WHAT YOU CAN CHECK"
has "names the real failure"    "Reading the function that performs a request"

echo
echo "── off-switch + well-formed output ──"
out=$(SERGE_INVESTIGATE_DIRECTIVE_DISABLE=1 run "why is it broken")
[ -z "$out" ] && ok "SERGE_INVESTIGATE_DIRECTIVE_DISABLE=1 → inert" || bad "off-switch ignored"

if run "why is it broken" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "UserPromptSubmit", h["hookEventName"]
c = h["additionalContext"]
assert c.startswith("<system-reminder>") and c.rstrip().endswith("</system-reminder>")
assert len(c) < 4000, len(c)
' 2>/dev/null; then ok "valid UserPromptSubmit additionalContext, bounded size"
else bad "malformed hook output"; fi

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL $pass PASS — investigation directive"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
