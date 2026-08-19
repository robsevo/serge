#!/usr/bin/env bash
# UserPromptSubmit hook — tell the LEAD it is in swarm mode, and how wide to go.
#
# WHY A SECOND HOOK: the fan-out decision is not the subagents' to make. They
# receive doctrine at SubagentStart, but by then the lead has already decided
# how many to spawn and what to put in each brief. `max_agents` therefore has to
# reach the LEAD, on the main thread, before it fans out — which is this event.
#
# Deliberately short. It rides on every prompt while swarm mode is on, so it is
# a few lines of operating instruction, not a second constitution. The doctrine
# lives on the subagent side where it is read once per spawn instead of once per
# turn.
#
# COST: zero while off. While on: this text, once per prompt.
#
# Toggles: SERGE_SWARM_DISABLE=1 · brief_lead:false in swarm.json
set -uo pipefail

[ "${SERGE_SWARM_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

CONF="${SERGE_SWARM_CONF:-$HOME/.serge/swarm.json}" python3 - "$input" <<'PY'
import json, os, sys

try:
    json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    pass  # the payload is not needed; this brief is unconditional while on

try:
    with open(os.environ.get("CONF", "")) as f:
        conf = json.load(f)
except Exception:
    sys.exit(0)

if not conf.get("enabled") or not conf.get("brief_lead", True):
    sys.exit(0)

n = conf.get("max_agents", 3)
who = str(conf.get("agents") or "*")
scope = "" if who == "*" else f" Doctrine is scoped to agent types matching `{who}`."

context = (
    f"SWARM MODE IS ON. Work that splits cleanly should be fanned out to parallel "
    f"agents, up to {n} at once.\n"
    f"- Split by AREA, never by file — two agents editing one file is a lost edit.\n"
    f"- Each brief must be self-contained: the agent sees no conversation history, "
    f"no CLAUDE.md and no memory. What the brief omits does not exist for it.\n"
    f"- Say what you expect back, so the results compose instead of overlapping.\n"
    f"- {n} is a ceiling, not a target. One agent is right for one question; "
    f"spawning to look busy spends free-tier quota you will want later.\n"
    f"- Subagents receive the swarm doctrine automatically — do not restate it in "
    f"the brief.{scope}"
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}))
PY
exit 0
