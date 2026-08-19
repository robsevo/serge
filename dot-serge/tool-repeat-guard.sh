#!/usr/bin/env bash
# Serge PostToolUse hook — tool-repeat escalation ladder ($0 per call, no LLM).
#
# Ported from MoonshotAI/kimi-code (MIT) packages/agent-core-v2/src/agent/
# toolDedupe/toolDedupeService.ts. When the SAME tool is called with the SAME
# arguments several times in a row, inject escalating system-reminders into
# the tool result via additionalContext:
#
#   streak 3-4 : R1 — "state what NEW information you expect before recalling"
#   streak 5-7 : R2 — forced three-way choice: falsification test / ask the
#                     user for the missing input / conclude with best result
#   streak 8+  : R3 — "write your final response now, no more tool calls"
#
# Why: the cheap free-tier seats (Mistral/Devstral/GLM) sometimes grind the
# same Grep/Read/Bash call for many steps mid-turn. The Stop pipeline only
# fires at turn END — this catches the loop while it is happening. Kimi's
# force-stop at streak 12 is not portable (PostToolUse can't end a turn), so
# R3 simply repeats; the Stop pipeline picks up from there.
#
# Safety:
#   1. Off-switch:  SERGE_TOOL_REPEAT_DISABLE=1
#   2. Exempt polling-by-design tools (TaskOutput, Monitor, TaskList, Sleep)
#      + extend via SERGE_TOOL_REPEAT_EXEMPT="Foo,Bar".
#   3. Streak resets the moment ANY different call is made — false positives
#      need 3 consecutive byte-identical (tool, args) pairs.
#   4. State is per-session in $TMPDIR; nothing persists across reboots.
#
# Wired as a PostToolUse hook (matcher "*") in ~/.serge/settings.json.
set -uo pipefail

[ "${SERGE_TOOL_REPEAT_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

tool = str(d.get("tool_name") or "")
if not tool:
    sys.exit(0)

EXEMPT = {"TaskOutput", "Monitor", "TaskList", "Sleep"}
EXEMPT |= {t.strip() for t in os.environ.get("SERGE_TOOL_REPEAT_EXEMPT", "").split(",") if t.strip()}

sid = str(d.get("session_id") or "nosid")
state_path = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-toolrepeat-" + hashlib.sha1(sid.encode()).hexdigest()[:12] + ".json",
)

# Canonical (tool, args) key — sorted keys so semantically identical inputs hash equal.
try:
    canon = json.dumps(d.get("tool_input"), sort_keys=True, separators=(",", ":"), default=str)
except Exception:
    canon = str(d.get("tool_input"))
key = hashlib.sha1((tool + "\x00" + canon).encode("utf-8", "ignore")).hexdigest()

try:
    with open(state_path) as fh:
        st = json.load(fh)
except Exception:
    st = {}

# An exempt tool neither counts nor breaks a streak elsewhere — it resets,
# matching the "consecutive" semantics (any different activity breaks a loop).
if tool in EXEMPT:
    streak = 0
else:
    streak = (int(st.get("streak", 0)) + 1) if st.get("key") == key else 1

try:
    with open(state_path, "w") as fh:
        json.dump({"key": key if streak else "", "streak": streak}, fh)
except Exception:
    pass

R1 = (
    "<system-reminder>\n"
    "The same tool call has been repeated several times in a row. "
    "Before making your next call, write one sentence stating what new information you expect it to produce. "
    "Then act on that sentence: if it names something this result does not already give you, "
    "choose the action that best provides it; otherwise, continue with the evidence you already have.\n"
    "</system-reminder>"
)

def r2(n):
    return (
        "<system-reminder>\n"
        f"The same tool call has now been issued {n} times in a row. "
        "Choose exactly one of the following and state your choice before acting:\n"
        "(1) Falsification check: run the cheapest test that could conclusively disprove your current approach, if such a test exists.\n"
        "(2) Missing input: tell the user precisely what information or decision you need to proceed, and ask for it.\n"
        "(3) Conclude: deliver your best result based on the evidence already gathered, listing anything that remains uncertain.\n"
        "</system-reminder>"
    )

R3 = (
    "<system-reminder>\n"
    "Write your final response now, without any further tool calls. "
    "Cover: the current blocker, each approach you have tried and what it established, "
    "and the specific information or decision you need from the user to unblock progress. "
    "Text only.\n"
    "</system-reminder>"
)

if streak >= 8:
    ctx = R3
elif streak >= 5:
    ctx = r2(streak)
elif streak >= 3:
    ctx = R1
else:
    sys.exit(0)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PostToolUse",
        "additionalContext": ctx,
    }
}))
PY
