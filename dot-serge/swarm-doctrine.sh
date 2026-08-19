#!/usr/bin/env bash
# SubagentStart hook — hand each spawned agent the swarm's mini-constitution.
#
# WHY HERE: SubagentStart is one of only seven events whose additionalContext is
# honoured, and runAgent.ts pushes what it returns into the subagent's
# initialMessages BEFORE its first turn (runAgent.ts:~561-584). So this is the
# one place doctrine can reach a subagent without touching the engine. The hook
# input carries agent_type, and the harness matches on it, so a measure can be
# scoped to reviewers or scouts without any code here knowing about them.
#
# WHY NOT THE MAIN CONSTITUTION: that one is always loaded and governs Serge
# itself. This is for agents spawned into a swarm, and only while swarm mode is
# on — an always-on rule for a sometimes-on situation is how prompts rot.
#
# COST: exactly zero while swarm mode is off — the first check exits before
# reading anything. While on, it is doctrine + enabled measures, once per spawn.
# That cost is multiplied by fan-out width, which is why swarm.sh reports it as
# "~N words × M agents" rather than letting it be invisible.
#
# Toggles: SERGE_SWARM_DISABLE=1 · SERGE_SWARM_CONF=<path>
set -uo pipefail

[ "${SERGE_SWARM_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

CONF="${SERGE_SWARM_CONF:-$HOME/.serge/swarm.json}" python3 - "$input" <<'PY'
import json, os, re, sys

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

conf_path = os.environ.get("CONF", "")
try:
    with open(conf_path) as f:
        conf = json.load(f)
except Exception:
    sys.exit(0)          # no config → nothing to inject, silently

if not conf.get("enabled"):
    sys.exit(0)          # off: the whole feature costs nothing here

agent_type = str(d.get("agent_type") or "")

# `agents` narrows which agent types get the doctrine. '*' = all. Anything else
# is a regex over agent_type, matching the harness's own matcher semantics so
# the two cannot drift apart. A broken regex must not silently apply doctrine to
# everything, so a compile error means inject nothing.
who = str(conf.get("agents") or "*").strip()
if who and who != "*":
    try:
        if not re.search(who, agent_type, re.I):
            sys.exit(0)
    except re.error:
        sys.exit(0)

parts = []
doc_path = os.path.expanduser(str(conf.get("doctrine_file") or ""))
try:
    with open(doc_path, encoding="utf-8") as f:
        body = f.read()
    # Drop the HTML comment block — it is editing guidance for the human, and
    # shipping it to every agent would be paying tokens to explain the file to
    # something that cannot edit it.
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S).strip()
    if body:
        parts.append(body)
except Exception:
    pass

# Measures are user-authored files; the config only names them. Anything the
# user drops in swarm-measures/ becomes available without touching this hook.
mdir = os.path.expanduser(str(conf.get("measures_dir") or "~/.serge/swarm-measures"))
for name in (conf.get("measures") or []):
    safe = os.path.basename(str(name))          # no traversal out of the dir
    p = os.path.join(mdir, safe + ".md")
    try:
        with open(p, encoding="utf-8") as f:
            m = re.sub(r"<!--.*?-->", "", f.read(), flags=re.S).strip()
        if m:
            parts.append("## " + safe.replace("-", " ") + "\n\n" + m)
    except Exception:
        continue                                 # a missing measure is not fatal

if not parts:
    sys.exit(0)

context = (
    "SWARM DOCTRINE — you are running as part of a swarm. These rules apply to "
    "this run and take precedence over your usual defaults where they differ.\n\n"
    + "\n\n".join(parts)
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext": context,
    }
}))
PY
exit 0
