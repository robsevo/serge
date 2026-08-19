#!/usr/bin/env bash
# Pattern tests for logic-directive.sh — $0, no LLM, no network. Verifies the
# LOGIC class fires on boolean/branch turns, the INGENUITY class fires when the
# obvious approach is exhausted, both can fire together, and ordinary turns stay
# quiet (a directive on every turn is just a token tax).
set -uo pipefail
HOOK="${SERGE_LOGIC_SCRIPT:-$HOME/.serge/logic-directive.sh}"
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
quiet() {  # quiet <label> <prompt>
  local out; out=$(run "$2")
  if [ -z "$out" ]; then ok "$1"; else bad "$1 — fired (out=${out:0:110})"; fi
}

echo "── LOGIC class ──"
fires "guard that never fires"            "why does this guard never fire?"                        "LOGIC RIGOR"
fires "equivalence claim"                 "are these two conditions equivalent after my refactor?" "LOGIC RIGOR"
fires "inverted condition"                "I think the condition is backwards in the auth check"   "LOGIC RIGOR"
fires "dead branch"                       "is that else branch dead code?"                         "LOGIC RIGOR"
fires "de morgan"                         "apply de morgan to this and keep it readable"           "LOGIC RIGOR"
fires "nested conditionals"               "flatten these nested ifs in the resolver"               "LOGIC RIGOR"
fires "looks right but behaves wrong"     "this conditional looks right but behaves wrong"         "LOGIC RIGOR"
fires "points at the checker"             "why does this guard never fire?"                        "logic_check.py"
fires "names the counterexample rule"     "are these two guards equivalent?"                       "COUNTEREXAMPLE"

echo
echo "── INGENUITY class ──"
fires "tried everything"                  "I've tried everything and the stream still cuts out"    "INGENUITY"
fires "keeps happening"                   "the freeze keeps happening on the Samsung"              "INGENUITY"
fires "asks for another way"              "is there a better way to do the token refresh?"         "INGENUITY"
fires "stuck"                             "I'm stuck on why the worker dies at 2am"                "INGENUITY"
fires "makes no sense"                    "this makes no sense, the file is right there"           "INGENUITY"
fires "explicit ask to be inventive"      "be creative here, the normal approach won't fit"        "INGENUITY"
fires "demands a second angle"            "I'm stuck on this deadlock"                             "SECOND, GENUINELY DIFFERENT ANGLE"

echo
echo "── both classes ──"
out=$(run "I'm stuck — this boolean guard never fires and I've tried everything")
if printf '%s' "$out" | grep -q "LOGIC RIGOR" && printf '%s' "$out" | grep -q "INGENUITY"; then
  ok "logic + ingenuity → both directives"
else bad "combined turn missed one class (out=${out:0:140})"; fi

echo
echo "── must stay quiet ──"
quiet "plain feature request"     "add a rate limiter to the upload endpoint"
quiet "plain question"            "what does this repo do?"
quiet "slash command"             "/sc:analyze the parser"
quiet "bare failure (G5 owns it)" "the page is still not working"
quiet "commit request"            "commit this with a sensible message"

out=$(SERGE_LOGIC_DIRECTIVE_DISABLE=1 run "why does this guard never fire?")
if [ -z "$out" ]; then ok "SERGE_LOGIC_DIRECTIVE_DISABLE=1 → hook inert"
else bad "off-switch ignored"; fi

# The injected context must be valid hook JSON, or the harness drops it silently.
out=$(run "why does this guard never fire?")
if printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
h=d["hookSpecificOutput"]
assert h["hookEventName"]=="UserPromptSubmit", h
assert h["additionalContext"].startswith("<system-reminder>")
assert h["additionalContext"].rstrip().endswith("</system-reminder>")
' 2>/dev/null; then ok "output is well-formed UserPromptSubmit hook JSON"
else bad "malformed hook JSON"; fi

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ ALL $pass PASS — logic/ingenuity directive trustworthy"
else
  echo "✗ $fail FAILED, $pass passed"; exit 1
fi
