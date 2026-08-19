#!/usr/bin/env bash
# Pattern tests for docs-directive.sh — $0, no LLM, no network. Verifies the
# directive fires on turns that PRODUCE a document, that README turns also get
# the genre contract, and that ordinary turns stay quiet (a directive on every
# turn is just a token tax).
set -uo pipefail
HOOK="${SERGE_DOCS_DIRECTIVE_SCRIPT:-$HOME/.serge/docs-directive.sh}"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

run() {
  printf '{"prompt":%s}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" \
    | bash "$HOOK"
}
fires() {  # fires <label> <prompt> <expected marker>
  local out; out=$(run "$2")
  if printf '%s' "$out" | grep -q "$3"; then ok "$1"
  else bad "$1 — missed (out=${out:0:110})"; fi
}
absent() {  # absent <label> <prompt> <marker that must NOT appear>
  local out; out=$(run "$2")
  if printf '%s' "$out" | grep -q "$3"; then bad "$1 — leaked '$3'"
  else ok "$1"; fi
}
quiet() {  # quiet <label> <prompt>
  local out; out=$(run "$2")
  if [ -z "$out" ]; then ok "$1"; else bad "$1 — fired (out=${out:0:110})"; fi
}

echo "── fires on document-producing turns ──"
fires "rewrite the readme"        "rewrite the readme for this project"          "DOCUMENTATION CRAFT"
fires "write a readme"            "write a README"                               "DOCUMENTATION CRAFT"
fires "update the docs"           "update the docs for the new flag"             "DOCUMENTATION CRAFT"
fires "flesh out contributing"    "flesh out CONTRIBUTING.md"                    "DOCUMENTATION CRAFT"
fires "document the api"          "document the api endpoints"                   "DOCUMENTATION CRAFT"
fires "install instructions"      "add install instructions to the project"      "DOCUMENTATION CRAFT"
fires "getting started guide"     "create a getting-started guide"               "DOCUMENTATION CRAFT"
fires "fix the changelog"         "fix the changelog entries for 1.2"            "DOCUMENTATION CRAFT"
fires "improve the tutorial"      "improve the tutorial, it is too thin"         "DOCUMENTATION CRAFT"

echo
echo "── the procedure the user actually asked for ──"
fires "names the genre step"      "rewrite the readme"                           "NAME THE GENRE"
fires "read existing file first"  "rewrite the readme"                           "READ THE EXISTING FILE IN FULL"
fires "ground claims in repo"     "rewrite the readme"                           "GROUND EVERY CLAIM IN THE REPO"
fires "first pass is final"       "rewrite the readme"                           "FIRST PASS IS THE FINAL PASS"
fires "verify before done-claim"  "rewrite the readme"                           "BEFORE CLAIMING IT IS DONE"

echo
echo "── README turns get the genre contract; other docs do not ──"
fires "readme contract present"   "rewrite the readme"                           "README CONTRACT"
fires "quickstart is required"    "write a readme for this cli"                  "QUICKSTART"
fires "install is required"       "write a readme for this cli"                  "INSTALL"
absent "changelog has no readme contract" "update the changelog for 1.2"         "README CONTRACT"
absent "api docs have no readme contract" "document the api endpoints"           "README CONTRACT"

echo
echo "── quiet on everything else ──"
quiet "plain code work"           "fix the retry loop in the router"
quiet "reading, not writing"      "read the readme and tell me what it says"
quiet "artifact without intent"   "what does the readme say about install?"
quiet "intent without artifact"   "write the parser for the config file"
quiet "slash command"             "/sc:implement readme parser"
quiet "empty prompt"              ""
quiet "document as a NOUN"        "the document the team wrote is out of date"
quiet "documented behaviour"      "is that the documented behavior of the retry loop?"
quiet "a document, not an order"  "a document the team keeps is enough"

echo
echo "── off-switch ──"
out=$(SERGE_DOCS_DIRECTIVE_DISABLE=1 run "rewrite the readme")
if [ -z "$out" ]; then ok "SERGE_DOCS_DIRECTIVE_DISABLE=1 → inert"
else bad "off-switch ignored (out=${out:0:110})"; fi

echo
echo "── output is well-formed hook JSON ──"
if run "rewrite the readme" | python3 -c '
import sys, json
d = json.load(sys.stdin)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "UserPromptSubmit", h["hookEventName"]
c = h["additionalContext"]
assert c.startswith("<system-reminder>") and c.rstrip().endswith("</system-reminder>")
assert len(c) < 6000, len(c)
' 2>/dev/null; then ok "emits valid UserPromptSubmit additionalContext, bounded size"
else bad "malformed hook output"; fi

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL $pass PASS — docs directive"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
