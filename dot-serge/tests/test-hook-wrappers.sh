#!/usr/bin/env bash
# Regression: UserPromptSubmit hooks must IGNORE harness plumbing (task notifications,
# system reminders) and still fire on real user prompts.
#
# Why this exists: on 2026-07-21, 13 of 45 auto-consult LLM calls fired on
# <task-notification> payloads — background-task completions arriving through
# UserPromptSubmit. That burned free-tier quota and added latency before every background
# completion, for zero value. All four hooks shared the blind spot.
#   ./test-hook-wrappers.sh   → exit 0 = hooks correctly scoped
set -uo pipefail
SH="${SERGE_HOME:-$HOME/.serge}"
n=0; fail=0
ck(){ n=$((n+1)); if [ "$1" = "$2" ]; then echo "✓ $3"; else fail=$((fail+1)); echo "✗ $3 (want $1, got $2)"; fi; }

# fired() → "yes" if the hook emitted anything (i.e. acted on the prompt)
fired() {
  local hook="$1" prompt="$2" out
  out="$(python3 -c "import json,sys;print(json.dumps({'prompt':sys.argv[1],'cwd':'/tmp','session_id':'t'}))" "$prompt" \
        | timeout 100 "$SH/$hook" 2>/dev/null)"
  [ -n "$out" ] && echo yes || echo no
}

NOTIF='[SYSTEM NOTIFICATION - NOT USER INPUT]
<task-notification>
<task-id>abc123</task-id>
<status>completed</status>
<summary>Background command "delete the old config and clean this up" completed</summary>
</task-notification>'

# 1. Harness plumbing must NOT trigger any hook — even though the text inside contains
#    trigger words ("delete the old", "clean this up") that would fire on a real prompt.
ck no "$(fired ambiguity-directive.sh "$NOTIF")" "ambiguity-directive ignores task-notification"
ck no "$(fired skill-learn.sh "$NOTIF")"        "skill-learn ignores task-notification"
ck no "$(fired auto-consult.sh "$NOTIF")"       "auto-consult ignores task-notification (no wasted LLM call)"

# 2. A real user prompt with the same words must STILL fire (we scoped, not broke, the hooks).
ck yes "$(fired ambiguity-directive.sh 'delete the old config we are not using')" \
   "ambiguity-directive still fires on a real ambiguous prompt"

# 3. A system-reminder wrapper alone is also plumbing.
ck no "$(fired ambiguity-directive.sh '<system-reminder>clean this up</system-reminder>')" \
   "ambiguity-directive ignores a bare system-reminder"

# 4. reference-resolve.sh (2026-07-29) joins the same contract: a notification
#    naming a path is plumbing, a user prompt naming one is not.
ck no "$(fired reference-resolve.sh "$NOTIF")" "reference-resolve ignores task-notification"
ck no "$(fired reference-resolve.sh '<system-reminder>read $SERGE_HOME/router.env</system-reminder>')" \
   "reference-resolve ignores a bare system-reminder"
ck yes "$(fired reference-resolve.sh 'what values go in $SERGE_HOME/router.env')" \
   "reference-resolve still fires on a real prompt naming a real path"

# 5. discovery-delegate.sh (2026-07-29) joins the same contract. cwd is /tmp in
#    fired(), so the size floor keeps it quiet regardless — assert the wrapper
#    scoping in its own suite's fixtures, and here only that plumbing is inert.
ck no "$(fired discovery-delegate.sh "$NOTIF")" "discovery-delegate ignores task-notification"

# 6. SERGE_EVAL scoping (2026-07-30). Evals measure the MODEL; a hook that feeds
#    context into a golden task makes its result incomparable to a baseline that
#    was recorded without it. Every CONTEXT-INJECTING hook must go silent under
#    SERGE_EVAL=1. The BLOCKING gates deliberately stay live — a gate that fires
#    during an eval is a real behavioural fact worth measuring, not scaffolding.
# A REAL project dir, not $HOME: repo-card deliberately stays silent at $HOME, so
# testing it there would pass whether or not the SERGE_EVAL guard exists.
EVAL_CWD="${SERGE_TEST_PROJECT:-$HOME/programs/serge-0.1.0}"
[ -d "$EVAL_CWD" ] || EVAL_CWD="$(mktemp -d)/proj"
mkdir -p "$EVAL_CWD/src" 2>/dev/null; : > "$EVAL_CWD/src/.keep" 2>/dev/null || true

eval_silent() { # eval_silent <hook> <event> -> "yes" if silent under SERGE_EVAL=1
  local hook="$1" ev="$2" out
  out="$(python3 -c "
import json,sys
print(json.dumps({'hook_event_name':sys.argv[1],'prompt':'where is the retry logic defined in this repo?',
 'cwd':sys.argv[2],'session_id':'evalguard','transcript_path':'/nonexistent.jsonl',
 'trigger':'auto','custom_instructions':None,'compact_summary':'x'}))" "$ev" "$EVAL_CWD" 2>/dev/null \
       | SERGE_EVAL=1 timeout 60 "$SH/$hook" 2>/dev/null)"
  [ -z "$out" ] && echo yes || echo no
}
ck yes "$(eval_silent reasoning-overlay.sh UserPromptSubmit)"  "reasoning-overlay silent under SERGE_EVAL"
ck yes "$(eval_silent reasoning-overlay.sh SessionStart)"      "reasoning-overlay silent under SERGE_EVAL (SessionStart)"
ck yes "$(eval_silent repo-card.sh SessionStart)"              "repo-card silent under SERGE_EVAL"
ck yes "$(eval_silent repo-card.sh SubagentStart)"             "repo-card silent under SERGE_EVAL (SubagentStart)"
ck yes "$(eval_silent reference-resolve.sh UserPromptSubmit)"  "reference-resolve silent under SERGE_EVAL"
ck yes "$(eval_silent discovery-delegate.sh UserPromptSubmit)" "discovery-delegate silent under SERGE_EVAL"
ck yes "$(eval_silent compact-survival.sh SessionStart)"       "compact-survival silent under SERGE_EVAL"

# Non-regression: the same hooks must still fire when SERGE_EVAL is NOT set.
# NOTE: fired() above omits hook_event_name, and the multi-event hooks refuse to
# act on an unidentified event on purpose (one script serves three events) — so
# these use an event-aware payload, exactly as the engine sends.
eval_off() { # eval_off <hook> <event> -> "yes" if it DOES emit with no SERGE_EVAL
  local out
  out="$(python3 -c "
import json,sys
print(json.dumps({'hook_event_name':sys.argv[1],'prompt':'why does the retry path fire twice?',
 'cwd':sys.argv[2],'session_id':'evaloff'}))" "$2" "$EVAL_CWD" 2>/dev/null \
       | timeout 60 "$SH/$1" 2>/dev/null)"
  [ -n "$out" ] && echo yes || echo no
}
ck yes "$(eval_off reasoning-overlay.sh UserPromptSubmit)" \
   "reasoning-overlay still fires in a normal session"
ck yes "$(eval_off repo-card.sh SessionStart)" \
   "repo-card still fires in a normal session"

echo ""
[ $fail -eq 0 ] && echo "✓ ALL $n PASS — hooks are correctly scoped to real user turns" || echo "✗ $fail/$n FAILED"
exit $((fail == 0 ? 0 : 1))
