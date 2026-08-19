#!/usr/bin/env bash
# Serge UserPromptSubmit hook — investigation discipline ($0, no LLM call).
#
# WHY (user report, 2026-08-16): asked why example-web's events tab was empty, serge
# issued one grep and four Reads, then produced a confident report headed
# "Verification Steps Taken" containing "Checked the ESPN API Directly" and
# "verified by the data.events array being empty". It had made no network call.
# It had read the FUNCTION that calls ESPN and narrated what that code would
# return as something observed. Its root cause — "ESPN returns no events" — was
# falsified by ONE curl: 11 MLS events for the date in question.
#
# Told to "go deeper", it launched three background agents, one of them named
# "Check ESPN API directly for MLS" — the five-second step it had already
# claimed to have done. It escalated to parallelism instead of doing the one
# observation that would have refuted its own answer.
#
# The user's ask was "go deeper so that doesn't happen again". Depth was not the
# missing ingredient — a deeper guess is still a guess, and a blanket
# always-maximum-depth rule is a latency and quota tax on a free-tier roster
# that has already collapsed once. What was missing is CONTACT WITH THE SYSTEM:
# an observation that could have come out the other way. So this directive is
# about grounding and falsification, not length.
#
# Scoped to diagnosis-shaped turns — "why is X broken", "troubleshoot", "debug",
# "not working" — because that is where a guess is cheapest and most expensive:
# no artifact exists to contradict it, so a wrong theory survives until the user
# notices. Ordinary build/edit turns are already covered by the feature-flow
# gate; docs by the doc gate; this covers the ANALYSIS turn, which had nothing.
#
# Enforcement partner: check 3c (grounding gate) in continue-on-unfinished.sh
# refuses a turn that CLAIMS external verification with no tool call that could
# have reached one. This directive tries to make that gate never fire.
#
# Cost: zero tokens on every turn that is not a diagnosis.
# Off-switch: SERGE_INVESTIGATE_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_INVESTIGATE_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, re

_WRAPPERS = (r"<system-reminder>.*?</system-reminder>"
             r"|<task-notification>.*?</task-notification>"
             r"|\[SYSTEM NOTIFICATION[^\]]*\]")

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

prompt = str(d.get("prompt") or "")
clean = re.sub(_WRAPPERS, " ", prompt, flags=re.S).strip()
if not clean or clean.startswith("/") or len(clean) > 8000:
    sys.exit(0)

# A turn that asks WHY something behaves as it does, or asks for a fault to be
# found. Deliberately narrow: "add a retry" is a build turn, not a diagnosis.
DIAGNOSE = re.compile(r"""
  \b(
      troubleshoot | debug(?:ging)? | diagnose | root[-\s]?cause | postmortem
    | why\s+(?:is|are|does|do|did|isn|aren|doesn|don|can|won|wasn)
    | what(?:'s|s|\s+is)\s+(?:wrong|going\s+on|happening|causing)
    | not\s+work(?:ing)? | isn't\s+work(?:ing)? | stopped\s+work(?:ing)?
    | doesn't\s+work | won't\s+(?:work|load|start|run|open)
    | broken | failing | fails | crash(?:es|ing)? | hang(?:s|ing)?
    | empty | blank | missing | no\s+data | nothing\s+shows
    | investigate | look\s+into | figure\s+out\s+why | find\s+out\s+why
    | go\s+deeper | dig\s+in(?:to)? | research\s+deeply
  )\b
""", re.IGNORECASE | re.VERBOSE)

if not DIAGNOSE.search(clean):
    sys.exit(0)

ctx = (
    "<system-reminder>\n"
    "INVESTIGATION DISCIPLINE — this turn diagnoses something. A diagnosis is only "
    "worth the observation behind it, so get contact with the real system BEFORE "
    "forming a theory.\n\n"

    "1. OBSERVE FIRST, THEORISE SECOND. Find the cheapest observation that could "
    "settle it and run it NOW — one curl against the real endpoint, one query, one "
    "command, one log line. Reading the function that performs a request is NOT "
    "performing it; reading the code path tells you what it INTENDS, never what it "
    "DID. If the system is reachable, touch it.\n\n"

    "2. TRY TO FALSIFY YOUR OWN ANSWER before you report it. State what you would "
    "expect to see if your theory were WRONG, then go look for exactly that. A "
    "hypothesis you never attacked is a guess with better formatting. If the user "
    "already told you something that contradicts it ('there were games yesterday'), "
    "that is your falsification test — run it first, not last.\n\n"

    "3. MARK EVERY CLAIM: observed or inferred. Write what you RAN and what it "
    "RETURNED, verbatim, and label anything you did not see as inference. Never "
    "write 'verified', 'confirmed' or 'checked' about something you did not "
    "execute — a report headed 'verified' that was not verified ends the "
    "investigation at a guess wearing the costume of a finding, and costs the user "
    "another round trip to discover.\n\n"

    "4. DON'T DELEGATE WHAT YOU CAN CHECK IN FIVE SECONDS. Spawning agents to "
    "confirm something a single command would settle is slower, costs more, and "
    "adds a layer between you and the evidence. Run the command.\n\n"

    "5. IF YOU GENUINELY CANNOT REACH IT, say so plainly, give the ONE command that "
    "would settle it, and state your best inference AS an inference. That is an "
    "honest stop; a confident unverified root cause is not.\n\n"

    "Depth is proportional to the question — a one-line answer grounded in one real "
    "observation beats five headed sections built on none.\n"
    "</system-reminder>"
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
