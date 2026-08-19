#!/usr/bin/env bash
# Serge reasoning overlay — SessionStart + UserPromptSubmit ($0, no LLM).
#
# WHY: ~/.serge/deliberate.md holds Serge's reasoning method (ASK / CHECK THE
# OBVIOUS ANSWER / GROUND IT / DECIDE / VERIFY, plus independence and evidence
# discipline). On 2026-07-29 it was found to be INERT: CLAUDE.md @-imports only
# CONSTITUTION.md, and the single reference to deliberate.md in
# logic-directive.sh is a COMMENT. The only real consumers were eval READMEs. The
# file describing how to think was loading in evals and nowhere else — the exact
# "the tool being installed is not the tool being used" trap that logic-directive
# was written to close.
#
# This wires it into the always-on path WITHOUT touching the constitution:
#   SessionStart      → the full method, once (~1k tokens).
#   UserPromptSubmit  → a compact kernel on substantive turns (~110 tokens), because
#                       a session-start instruction fades and the seat has no hidden
#                       reasoning channel: whatever is not in front of it now is not
#                       operating now.
#
# Cost dial: SERGE_REASONING_KERNEL=0 keeps the session-start load and drops the
# per-turn kernel. Off entirely: SERGE_REASONING_OVERLAY_DISABLE=1.
#
# Honest scope: this changes METHOD, not capacity. A stronger method makes a weak
# seat check itself; it does not make it a stronger reasoner. The capacity levers
# are seat choice and escalation (auto-consult.sh, the council ladder), not prose.
set -uo pipefail

[ "${SERGE_REASONING_OVERLAY_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the MODEL, not the scaffolding. Injecting a reasoning method into
# a golden-task run makes eval deltas unattributable — and the recorded baseline
# predates this hook, so leaving it on would read as a model change that never
# happened. Same guard as notifications-load.sh / persist-plan.sh / semgrep-scan.sh.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

python3 - "$input" <<'PY'
import sys, json, os, re

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

event = str(d.get("hook_event_name") or "")
HOME = os.path.expanduser("~")
DELIB = os.path.join(HOME, ".serge", "deliberate.md")


def emit(ev, ctx):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": ev,
        "additionalContext": ctx,
    }}))
    sys.exit(0)


# ----------------------------------------------------- session start: full ---
if event == "SessionStart":
    try:
        with open(DELIB, encoding="utf-8") as fh:
            body = fh.read().strip()
    except Exception:
        sys.exit(0)
    if not body:
        sys.exit(0)
    emit(
        "SessionStart",
        "How you are expected to reason this session (this is method, not "
        "narration — apply it, don't recite it):\n\n" + body,
    )

# ------------------------------------------------- every prompt: the kernel ---
if event != "UserPromptSubmit":
    sys.exit(0)
if os.environ.get("SERGE_REASONING_KERNEL", "1") == "0":
    sys.exit(0)

_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"
prompt = re.sub(_WRAPPERS, " ", str(d.get("prompt") or ""), flags=re.S).strip()
if not prompt:
    sys.exit(0)

# Pure acknowledgements carry no work to reason about. "continue" is NOT one of
# these — it resumes real work and is exactly when the method matters.
if re.fullmatch(
    r"(ok(ay)?|thanks?|thank you|ty|yes|yep|yeah|no|nope|y|n|sure|got it|nice|cool|"
    r"perfect|great|done)[!.\s]*",
    prompt,
    re.IGNORECASE,
):
    sys.exit(0)
# Slash commands carry their own instructions.
if prompt.startswith("/"):
    sys.exit(0)

emit(
    "UserPromptSubmit",
    "<system-reminder>\n"
    "Reasoning kernel — full method in ~/.serge/deliberate.md:\n"
    "- Your first instinct is a draft. State it, try to break it, THEN answer.\n"
    "- Anything about this codebase: read the real file first. Never a path, "
    "symbol, flag, or key from memory.\n"
    "- A checkable claim gets checked. \"Probably / should be / I believe\" means "
    "go look.\n"
    "- A tool failure is a detour: change the route, not the volume. Two more "
    "angles before you call anything blocked.\n"
    "- Never ask for what a command can answer. Deliver every part that isn't "
    "blocked, then ask the one question that is.\n"
    "- Absence of a symptom proves nothing — find the positive signal that your "
    "change caused the result.\n"
    "- Hold your position on evidence. Change it on new evidence, not on pressure.\n"
    # Kept deliberately terse: the kernel is charged on every substantive turn and
    # is capped at 900 chars by tests/test-reasoning-overlay.sh. The full procedure
    # lives in deliberate.md and complexity-directive.sh; this is just the habit.
    "- Loop, lookup or query? State n and the Big-O before writing it; index "
    "once, never scan inside the loop.\n"
    "</system-reminder>",
)
PY
exit 0
