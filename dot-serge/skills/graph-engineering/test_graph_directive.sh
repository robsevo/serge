#!/usr/bin/env bash
# Trigger tests for ~/.serge/graph-directive.sh
# Run: bash ~/.serge/skills/graph-engineering/test_graph_directive.sh
#
# The directive is benign in both directions (a false positive costs a few tokens),
# so these tests guard the two things that actually matter:
#   - it FIRES on orchestration/edge-loss shapes (otherwise the skill is inert)
#   - it stays QUIET on the "graph" homonyms that dominate this box: charts,
#     knowledge graphs, dependency graphs — and on harness plumbing.
set -uo pipefail

HOOK="${HOME}/.serge/graph-directive.sh"
[ -x "$HOOK" ] || { echo "FAIL: $HOOK not executable"; exit 1; }

pass=0; fail=0

t() { # t <FIRE|quiet> <prompt>
  local want="$1" prompt="$2" out got kinds
  out=$(python3 -c "import json,sys;print(json.dumps({'prompt':sys.argv[1]}))" "$prompt" | "$HOOK")
  if [ -n "$out" ]; then
    got="FIRE"
    kinds=$(printf '%s' "$out" | grep -o 'GRAPH ENGINEERING\|EDGE LOSS' | tr '\n' ' ')
  else
    got="quiet"; kinds=""
  fi
  if [ "$want" = "$got" ]; then
    pass=$((pass+1)); printf '  ok    [%s %s] %s\n' "$got" "$kinds" "$prompt"
  else
    fail=$((fail+1)); printf '  FAIL  expected=%s got=%s :: %s\n' "$want" "$got" "$prompt"
  fi
}

echo "== should FIRE — orchestration =="
t FIRE "can you have a few agents look at this in parallel?"
t FIRE "spawn 3 subagents to audit the codebase"
t FIRE "which specialist should handle the auth refactor?"
t FIRE "what can run in parallel here?"
t FIRE "set up a pipeline with stages for the migration"
t FIRE "lets do a multi-agent review of the player"
t FIRE "who should do the backend part?"
t FIRE "convene the council on this"
t FIRE "fan out a few scouts over the lib directory"
t FIRE "delegate the audit to some specialists"

echo "== should FIRE — edge loss =="
t FIRE "the reviewer didn't know about the new schema"
t FIRE "we keep losing context between the agents"
t FIRE "two scouts repeated the same work"
t FIRE "the subagent never saw the failing test"

echo "== should stay QUIET — 'graph' homonyms and ordinary work =="
t quiet "fix the login button padding"
t quiet "plot a graph of the results"
t quiet "add a knowledge graph to the app"
t quiet "the dependency graph has a cycle in it"
t quiet "why does this guard never fire?"
t quiet "run npm build and npm test in parallel"
t quiet "deploy example-web to vercel"

echo "== should stay QUIET — harness plumbing and malformed input =="
t quiet "<system-reminder>spawn several agents in parallel</system-reminder>"
t quiet "/sc:spawn multiple agents"

printf '%s' 'not json' | "$HOOK" >/dev/null 2>&1 \
  && { pass=$((pass+1)); echo "  ok    [fails open] malformed json"; } \
  || { fail=$((fail+1)); echo "  FAIL  malformed json did not exit 0"; }

printf '%s' '{"prompt":"spawn 3 subagents"}' | "$HOOK" | python3 -c "
import json,sys
o=json.load(sys.stdin)['hookSpecificOutput']
assert o['hookEventName']=='UserPromptSubmit'
c=o['additionalContext']
assert c.startswith('<system-reminder>') and c.endswith('</system-reminder>')
" 2>/dev/null \
  && { pass=$((pass+1)); echo "  ok    [shape] hookSpecificOutput / system-reminder wrapping"; } \
  || { fail=$((fail+1)); echo "  FAIL  output shape invalid"; }

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
