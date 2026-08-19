#!/usr/bin/env bash
# Tests for the STALL / PARKED detection in continue-on-unfinished.sh — the
# "serge narrates a next step, then stops" flow-breaker.
#
# Every case below is either a pattern taken from a real missed stall in
# ~/.serge/projects/*/*.jsonl, or a guard against over-blocking (a legitimate
# stop that must stay legitimate). Synthetic transcripts, no LLM, no network.
# Guard files are isolated via TMPDIR; each case gets its own session id.
set -uo pipefail

HOOK="${SERGE_PERSIST_SCRIPT:-$HOME/.serge/continue-on-unfinished.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

n=0
# tx <final_text> [user_text] → path to a transcript whose last assistant row is
# that text, preceded by a turn that made a (non-edit) tool call.
tx() {
  n=$((n+1)); local f="$T/tx$n"
  python3 - "$f" "$1" "${2:-fix the parser bug}" <<'PY'
import json, sys
f, final, user = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [
  {"type": "user", "message": {"role": "user", "content": user}},
  {"type": "assistant", "message": {"role": "assistant", "content": [
      {"type": "text", "text": "working"},
      {"type": "tool_use", "name": "Read", "input": {"file_path": "/tmp/app/parser.ts"}}]}},
  {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": final}]}},
]
with open(f, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
  printf '%s' "$f"
}

# stale_tx — transcript whose last row is a tool_use (the D1 race: the final
# assistant text has not been flushed to disk yet).
stale_tx() {
  n=$((n+1)); local f="$T/tx$n"
  {
    printf '{"type":"user","message":{"content":"fix the parser bug"}}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/app/parser.ts"}}]}}\n'
  } > "$f"
  printf '%s' "$f"
}

run() {  # run <transcript> <session> [last_assistant_message]
  if [ "$#" -ge 3 ]; then
    python3 -c '
import json,sys
print(json.dumps({"transcript_path":sys.argv[1],"session_id":sys.argv[2],"last_assistant_message":sys.argv[3]}))' \
      "$1" "$2" "$3" | bash "$HOOK"
  else
    printf '{"transcript_path":"%s","session_id":"%s"}' "$1" "$2" | bash "$HOOK"
  fi
}

blocks() {  # blocks <label> <final_text> [expect_substring]
  local label="$1" text="$2" want="${3:-}"
  n=$((n+1)); local sid="s$n"
  local out; out=$(run "$(tx "$text")" "$sid")
  if ! printf '%s' "$out" | grep -q '"decision": "block"'; then
    bad "$label — NOT blocked"; return
  fi
  if [ -n "$want" ] && ! printf '%s' "$out" | grep -qi "$want"; then
    bad "$label — blocked but wrong reason (want '$want')"; return
  fi
  ok "$label"
}

allows() {  # allows <label> <final_text> [user_text]
  local label="$1" text="$2" user="${3:-fix the parser bug}"
  n=$((n+1)); local sid="s$n"
  local out; out=$(run "$(tx "$text" "$user")" "$sid")
  if [ -z "$out" ]; then ok "$label"; else bad "$label — blocked (out=${out:0:120})"; fi
}

echo "── must BLOCK: announced-but-untaken next step ──"
blocks "bare announcement" \
  "Hey, let me go verify that for you."
blocks "D2: announcement after \"here's the fix\" (allow-list pre-emption)" \
  "The root cause is the off-by-one in the tokenizer. Here's the fix: bump the index. Let me verify that for you."
blocks "D2: announcement after a \"Summary:\" line" \
  "Summary: the loop never terminates. I'll go run the tests now."
blocks "D2: announcement after a \"let me know\" courtesy line" \
  "The patch is applied. Let me know if you want more. Now let me run the suite."
blocks "D2: announcement after \"That's done.\"" \
  "That's done. Let me double-check the imports."
blocks "D3: telegraphic participle" \
  "Good catch. Checking the config now..."
blocks "D3: \"On it\" idiom" \
  "On it — pulling up the logs."
blocks "D3: bare gerund clause" \
  "That looks wrong. Investigating the stream handler."
blocks "real miss (row 84)" \
  "The vod-extract and vod-stream routes are both API routes. I have read lib/vod-resolve.ts, which is a core component. Now I'll read the vod-stream/route.ts, vodPrewarm.ts and streamToken.ts files. I will read them in parallel since they don't have dependencies."

echo
echo "── must BLOCK: parked on self-dispatched background work (D4) ──"
blocks "parked: synthesize once agents complete" \
  "I have dispatched two agents. I'll synthesize their findings into a concrete plan once they complete." \
  "parked on background work"
blocks "parked: waiting for the agent to report" \
  "The fix is staged. I will wait for the agent to report its findings and then confirm the fix to you." \
  "parked on background work"
blocks "parked: results will arrive as notifications" \
  "Three agents are running. Results will arrive as notifications." \
  "parked on background work"
blocks "parked: \"you\" nearby but the wait is on an agent" \
  "Still waiting on the researcher — I'll let you know as soon as it lands." \
  "parked on background work"
blocks "parked: awaiting the verifier's completion" \
  "The verification agent is currently running in the background. I am awaiting its completion to provide the results." \
  "parked on background work"

echo
echo "── D6: background work STILL RUNNING → park nudge stays silent ──"
# The harness reports in-flight work as background_tasks_running. D4 must not fire
# then: the job wakes the session when it lands, so prodding only buys filler.
run_bg() {  # run_bg <transcript> <session> <last_assistant_message> <bg_count>
  python3 -c '
import json,sys
print(json.dumps({"transcript_path":sys.argv[1],"session_id":sys.argv[2],
                  "last_assistant_message":sys.argv[3],
                  "background_tasks_running":int(sys.argv[4])}))' \
    "$1" "$2" "$3" "$4" | bash "$HOOK"
}

# The live regression, verbatim from the user's report. Note it does NOT match
# PARKED (no "once they complete" / "waiting on") — it tripped the STALL check on
# "I will synthesize…". That is why the guard needs BG_CONTINGENT too.
LIVE_TEXT="I am genuinely blocked because the background research and analysis agents are still running and have not yet returned their results. I will synthesize the findings immediately upon their completion."

n=$((n+1))
out=$(run_bg "$(tx "$LIVE_TEXT")" "bg1" "$LIVE_TEXT" 2)
if [ -z "$out" ]; then ok "live regression + 2 running → silent"; else bad "live regression + 2 running → still blocked (out=${out:0:140})"; fi

# Nothing in flight ⇒ the same sentence is an unkept promise and must still block.
n=$((n+1))
out=$(run_bg "$(tx "$LIVE_TEXT")" "bg2" "$LIVE_TEXT" 0)
if printf '%s' "$out" | grep -q '"decision": "block"'; then ok "live regression + 0 running → still blocks"; else bad "live regression + 0 running → wrongly silent"; fi

# A PARKED-shaped park: silent while running, D4 when nothing is.
PARKED_TEXT="I have dispatched two agents. I'll synthesize their findings into a concrete plan once they complete."
n=$((n+1))
out=$(run_bg "$(tx "$PARKED_TEXT")" "bg3" "$PARKED_TEXT" 1)
if [ -z "$out" ]; then ok "parked text + 1 running → silent"; else bad "parked text + 1 running → still blocked"; fi

n=$((n+1))
out=$(run_bg "$(tx "$PARKED_TEXT")" "bg4" "$PARKED_TEXT" 0)
if printf '%s' "$out" | grep -qi "parked on background work"; then ok "parked text + 0 running → D4 still fires"; else bad "parked text + 0 running → D4 stopped firing"; fi

# Scope: an announcement unrelated to the running job is still a stall.
n=$((n+1))
out=$(run_bg "$(tx "Hey, let me go verify that for you.")" "bg5" "Hey, let me go verify that for you." 3)
if printf '%s' "$out" | grep -q '"decision": "block"'; then ok "unrelated stall + 3 running → still blocks"; else bad "unrelated stall + 3 running → wrongly suppressed"; fi

echo
echo "── must BLOCK: D1 transcript race (final text only in-band) ──"
n=$((n+1))
out=$(run "$(stale_tx)" "race1" "Right, let me go verify that for you.")
if printf '%s' "$out" | grep -q '"decision": "block"'; then
  ok "unflushed transcript + last_assistant_message → still blocked"
else bad "D1 race — not blocked (out=${out:0:120})"; fi

n=$((n+1))
out=$(run "$(stale_tx)" "race2" "Fixed the off-by-one at parser.ts:88; the suite passes 412/412.")
if [ -z "$out" ]; then ok "unflushed transcript + genuine completion → allowed"
else bad "D1 race — false block (out=${out:0:120})"; fi

echo
echo "── must BLOCK: over-ask — permission to do what was just ordered ──"
n=$((n+1)); out=$(run "$(tx "I found the bug at parser.ts:88. Would you like me to fix the parser bug?" "fix the parser bug")" "oa1")
if printf '%s' "$out" | grep -q "already told to do"; then ok "offers to do the exact order → blocked"
else bad "over-ask not blocked (out=${out:0:120})"; fi
n=$((n+1)); out=$(run "$(tx "Found it. Shall I add the rate limiter now?" "add a rate limiter to the upload endpoint")" "oa2")
if printf '%s' "$out" | grep -q "already told to do"; then ok "shall-I over the ordered work → blocked"
else bad "over-ask variant not blocked (out=${out:0:120})"; fi

echo
echo "── must BLOCK: plan presented, nothing executed ──"
n=$((n+1)); out=$(run "$(tx "Here is the plan:
1. Add the rate-limit middleware to the upload route
2. Wire the config into settings.json
3. Run the suite" "add rate limiting to uploads")" "pl1")
if printf '%s' "$out" | grep -q "step plan without executing"; then ok "3-step plan, no edits → blocked"
else bad "plan-not-executed missed (out=${out:0:120})"; fi

echo
echo "── must BLOCK: asking permission to begin, empty answers, dropped intent ──"
n=$((n+1)); out=$(run "$(tx "**Next Steps**: I will start by:
1. Adding the serverless functions
2. Updating the frontend
Should I proceed?" "add phone lookup to the leads page")" "gp1")
if printf '%s' "$out" | grep -q "permission to begin"; then ok "\"Should I proceed?\" over an outstanding order → blocked"
else bad "generic proceed not blocked (out=${out:0:120})"; fi

n=$((n+1)); out=$(run "$(tx "I am ready to proceed with this plan. Do you have any concerns or should I start implementation?" "wire up the DNCL check")" "gp2")
if printf '%s' "$out" | grep -q "permission to begin"; then ok "\"any concerns / should I start\" → blocked"
else bad "concerns variant not blocked (out=${out:0:120})"; fi

n=$((n+1)); out=$(run "$(tx "[Tool results received]" "fix the parser bug")" "ea1")
if printf '%s' "$out" | grep -q "carried no content"; then ok "content-free final message → blocked"
else bad "empty answer not blocked (out=${out:0:120})"; fi

n=$((n+1)); out=$(run "$(tx "No response requested." "fix the parser bug")" "ea2")
if printf '%s' "$out" | grep -q "carried no content"; then ok "\"No response requested.\" → blocked"
else bad "empty answer variant not blocked (out=${out:0:120})"; fi

blocks "dropped intent (past-tense announcement)" \
  "The existing extractors target dead providers and xpass is the clear replacement. I was about to implement the xpass extractor and wire it into the orchestrator. That is the remaining two steps."

echo
echo "── must ALLOW: legitimate stops ──"
n=$((n+1)); out=$(run "$(tx "No response requested." "[Request interrupted by user for tool use]")" "int1")
if [ -z "$out" ]; then ok "user interrupted the turn → hook stays out of it"
else bad "nudged a user-interrupted turn (out=${out:0:110})"; fi
n=$((n+1)); out=$(run "$(tx "OK" "Reply with exactly: OK")" "lit1")
if [ -z "$out" ]; then ok "terse reply that was literally requested → allowed"
else bad "nudged a correct literal reply (out=${out:0:110})"; fi
allows "menu of options, not a plan" \
  "You have three routes here:
- **Container host**: move to a VPS or Fly.io that supports Playwright
- **Scraping API**: swap in a third-party service, needs an API key
- **Drop the feature**: ship without phone lookup" \
  "continue"
allows "asking before an irreversible deploy" \
  "The build is green and the tests pass. Should I proceed with the deployment to production?" \
  "get the build green"
allows "recap of completed steps (past tense)" \
  "Done:
1. Fixed the off-by-one at parser.ts:88
2. Added a regression test
3. Ran the suite — 412/412 green"
allows "plan when the user ASKED for a plan" \
  "Here is the plan:
1. Add the middleware
2. Wire the config
3. Run the suite" \
  "what's your plan for rate limiting?"
allows "offer of unrelated extra work" \
  "The parser bug is fixed at line 88. Would you like me to also check the leads page?" \
  "fix the parser bug"
allows "genuine either/or fork" \
  "There are two ways to do this — a guard clause or an early return. Want me to use the guard?" \
  "fix the parser bug"
allows "irreversible action still asks" \
  "The build is green. Should I deploy to production?" \
  "deploy the new build"
allows "plain completion report" \
  "Fixed the off-by-one at parser.ts:88 and the suite passes (412/412)."
allows "question to the user" \
  "There are two ways to do this. Want me to verify it now?"
allows "hand-back: let me know" \
  "The refactor is in place and the tests are green. Let me know if you want the tests split out too."
allows "hand-back: waiting on the user's call" \
  "Deploying is outward-facing, so I'll wait for your call before pushing."
allows "hand-back: needs your key" \
  "The client is wired up. I need your API key to run the live check."
allows "report that starts with a participle" \
  "Running the suite gave 412 passes and 0 failures."
allows "checkmark sign-off" \
  "✅ All set — the parser and its tests are green."
allows "recap containing \"let me\" but closing on completion" \
  "Let me recap what changed: the tokenizer index, the guard clause, and the test fixture. All set."
allows "past-tense finding, no announcement" \
  "I've read the file. The bug is at parser.ts:88, where the index is incremented before the bounds check."
allows "honest untested disclosure" \
  "The rate limiter is built but NOT yet tested — the auth path remains unverified."
allows "irreversible action needs explicit approval" \
  "The verification agent returned a PASS. I will need your explicit confirmation before deploying to your TV environment, as this is non-reversible."
allows "job still running but the user can watch it" \
  "The deployment is in progress. Once it completes, you can test the phone lookup live. You can monitor the status here: [Vercel Dashboard](https://vercel.com/dashboard)"
allows "idle at the prompt, awaiting a task" \
  "No further changes are needed. Awaiting task."
allows "bulleted plan under a question to the user" \
  "Would you like me to verify that the leads page is working? This would include: - Verifying the page loads - Checking that the data is displayed - Testing the phone lookup"

echo
echo "── D5: silent turn (thinking-only, zero text blocks) ──"
# Real shape from voicebot: the last assistant row is a thinking
# block and nothing else, and the harness passes last_assistant_message as "".
silent_tx() {
  n=$((n+1)); local f="$T/tx$n"
  python3 - "$f" "${1:-give me an answer. is everything done?}" <<'PY'
import json, sys
f, user = sys.argv[1], sys.argv[2]
rows = [
  {"type": "user", "message": {"role": "user", "content": user}},
  {"type": "assistant", "message": {"role": "assistant",
   "content": [{"type": "thinking", "thinking": "long private reasoning, no text emitted"}]}},
]
with open(f, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
  printf '%s' "$f"
}

n=$((n+1)); out=$(run "$(silent_tx)" "sil$n" "")
if printf '%s' "$out" | grep -q '"decision": "block"' &&
   printf '%s' "$out" | grep -qi "without emitting any text"; then
  ok "empty last_assistant_message → nudged"
else bad "silent turn NOT nudged (out=${out:0:120})"; fi

# Key ABSENT is a different state (no final message, or a pre-fix build) and must
# still take the old transcript fallback rather than nudging.
n=$((n+1)); out=$(run "$(silent_tx)" "sil$n")
if [ -z "$out" ]; then ok "absent last_assistant_message → no nudge (fallback path)"
else bad "nudged on absent key (out=${out:0:120})"; fi

# Never fight Esc, even on a silent turn.
n=$((n+1)); out=$(run "$(silent_tx "[Request interrupted by user]")" "sil$n" "")
if [ -z "$out" ]; then ok "silent turn after user interrupt → not nudged"
else bad "fought the user's interrupt (out=${out:0:120})"; fi

# A real answer must never trip Check 0.
n=$((n+1)); out=$(run "$(silent_tx)" "sil$n" "Done — 3 files changed, tests pass.")
if [ -z "$out" ]; then ok "non-empty answer → Check 0 inert"
else bad "Check 0 fired on a real answer (out=${out:0:120})"; fi

# Each NEW user prod re-arms exactly one nudge (hash keyed on user text, not on
# the constant empty string) — otherwise only the first silent turn is caught.
# NB: silent_tx runs in a $(…) subshell, so its `n` increment does not reach the
# parent — two calls would return the SAME path and the second would clobber the
# first. Write these two with explicit distinct names.
silent_tx_at() {  # silent_tx_at <path> <user_text>
  python3 - "$1" "$2" <<'PY'
import json, sys
f, user = sys.argv[1], sys.argv[2]
rows = [
  {"type": "user", "message": {"role": "user", "content": user}},
  {"type": "assistant", "message": {"role": "assistant",
   "content": [{"type": "thinking", "thinking": "long private reasoning, no text emitted"}]}},
]
with open(f, "w") as fh:
    for r in rows:
        fh.write(json.dumps(r) + "\n")
PY
}
f1="$T/rearm1.jsonl"; f2="$T/rearm2.jsonl"
silent_tx_at "$f1" "continue? why did you stop"
silent_tx_at "$f2" "hey serge whats up"
o1=$(run "$f1" rearm ""); o2=$(run "$f1" rearm ""); o3=$(run "$f2" rearm "")
# o2 used to be asserted EMPTY. Since 2026-08-15 a silent turn that has already
# been nudged and still produced no text emits the deterministic receipt instead
# of nothing (see tests/test-silent-turn-receipt.sh) — that give-up moment is
# precisely the "serge just stopped" the user sees, so silence there was the bug.
# What this test is actually about is the RE-ARM rule, so assert that: o2 must
# not re-nudge, o3 (new user prod) must. Checking "not a block" instead of "no
# output" keeps the real invariant and stops the assertion breaking every time
# the give-up path learns to say something.
if printf '%s' "$o1" | grep -q '"decision": "block"' &&
   ! printf '%s' "$o2" | grep -q '"decision": "block"' &&
   printf '%s' "$o3" | grep -q '"decision": "block"'; then
  ok "new user prod re-arms the nudge; identical repeat does not"
else bad "re-arm logic wrong (o1=${o1:0:40} o2=${o2:0:40} o3=${o3:0:40})"; fi

echo
echo "── safety rails ──"
STALL="Alright, let me go check the logs."
f=$(tx "$STALL")
out1=$(run "$f" loopsid); out2=$(run "$f" loopsid)
if printf '%s' "$out1" | grep -q '"decision": "block"' && [ -z "$out2" ]; then
  ok "identical text re-run → not re-nudged (anti-loop)"
else bad "anti-loop guard broken (out2=${out2:0:80})"; fi

out=$(SERGE_AUTOCONTINUE_DISABLE=1 run "$f" offsid)
if [ -z "$out" ]; then ok "SERGE_AUTOCONTINUE_DISABLE=1 → hook inert"
else bad "off-switch ignored"; fi

out=$(SERGE_AUTOCONTINUE_CAP=0 run "$(tx "Let me go check the logs one more time.")" capsid)
if [ -z "$out" ]; then ok "SERGE_AUTOCONTINUE_CAP=0 → cap respected"
else bad "cap ignored"; fi

echo
if [ "$fail" -eq 0 ]; then
  echo "✓ ALL $pass PASS — stall detection trustworthy"
else
  echo "✗ $fail FAILED, $pass passed"; exit 1
fi
