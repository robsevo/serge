#!/usr/bin/env bash
# Serge subagent refs gate — SubagentStop on discovery agents ($0, no LLM).
#
# WHY: the whole point of a scout is to come back with LOCATIONS — "it's in
# src/foo.ts:42" — so the driver keeps the conclusion and throws away the search.
# A scout that returns prose ("the retry logic is handled in the client module")
# has cost a subagent call and left the driver exactly where it started: knowing
# a claim, unable to cite it, and one step from inventing the path. That is the
# failure this whole hook family exists to stop, and the subagent boundary was
# the only place still unchecked.
#
# CONTRACT (verified in this fork, not assumed):
#   - SubagentStop routes its matcher on agent_type (hooks.ts:1849), so this gate
#     applies ONLY to discovery-shaped agents.
#   - It runs the same execution path as Stop (hooks.ts:3918
#     `subagentId ? 'SubagentStop' : 'Stop'`) and blocks on exit 2 or
#     decision:"block" (hooks.ts:3531).
#   - It is NOT one of the seven events that accept additionalContext
#     (hooks.ts:805-845), so blocking with a reason is the only lever available.
#   - last_assistant_message carries the subagent's final text.
#
# BLOCK ONCE per agent, then get out of the way: a second stop from the same
# agent passes regardless, so a stubborn or genuinely ref-less answer costs one
# extra turn and never deadlocks.
#
# Safety: off-switch SERGE_SUBAGENT_REFS_DISABLE=1 · fails open on any error ·
# stays silent when the agent legitimately found nothing · only fires for agent
# types listed in SERGE_REFS_AGENTS (default scout,researcher,Explore).
set -uo pipefail

[ "${SERGE_SUBAGENT_REFS_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

python3 - "$input" <<'PY'
import sys, json, os, re, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "SubagentStop":
    sys.exit(0)

agents = {a.strip().lower() for a in
          os.environ.get("SERGE_REFS_AGENTS", "scout,researcher,explore").split(",")
          if a.strip()}
atype = str(d.get("agent_type") or "").lower()
if atype not in agents:
    sys.exit(0)

msg = str(d.get("last_assistant_message") or "")
if not msg.strip():
    sys.exit(0)          # nothing to judge; the harness handles empty results

# Block once per agent.
aid = str(d.get("agent_id") or d.get("session_id") or "noagent")
mark = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                    "serge-refsgate-%s" % hashlib.sha1(aid.encode()).hexdigest()[:16])
if os.path.exists(mark):
    sys.exit(0)

# "I looked and it isn't there" is a legitimate, useful answer — never punish it.
# Generous on purpose: letting a vague answer through costs one weak reply, but
# blocking a correct "it genuinely isn't there" punishes the right behaviour and
# sends the scout hunting for a reference that cannot exist.
NOTFOUND = re.compile(
    r"\b(no (?:such|matching|relevant)|not (?:found|present|defined|implemented)|"
    r"nothing (?:found|matches)|does(?:n't| not) (?:exist|appear)|"
    r"could ?n(?:o|')t find|did ?n(?:o|')t find|(?:found|find) (?:no|nothing)|"
    r"there (?:is|are) no\b|no [\w \-]{0,40}?(?:exists?|anywhere|at all)|"
    r"no results?|absent from)\b", re.I)
if NOTFOUND.search(msg):
    sys.exit(0)

# A real location: path/to/file.ext optionally with :line, or a bare filename
# with an extension. Deliberately generous — one honest ref is enough.
REF = re.compile(
    r"(?:[\w.\-]+/)+[\w.\-]+\.[A-Za-z0-9]{1,6}(?::\d+)?"      # a/b/c.ts[:42]
    r"|\b[\w.\-]+\.[A-Za-z0-9]{1,6}:\d+"                       # file.ts:42
    r"|\b[\w.\-]+\.(?:ts|tsx|js|jsx|mjs|cjs|py|rb|go|rs|java|c|h|cpp|sh|bash|"
    r"json|ya?ml|toml|md|sql|css|html)\b")
if REF.search(msg):
    sys.exit(0)

try:
    open(mark, "w").close()
except Exception:
    pass

print(json.dumps({
    "decision": "block",
    "reason": (
        "Your answer names no location. A %s exists so the main agent can keep a "
        "conclusion AND cite it — prose without references just moves the search "
        "back to the caller, who will be tempted to guess the path.\n\n"
        "Re-answer with the same finding, but cite the evidence: file paths as "
        "path/to/file.ext, with :line where you actually read it. If the answer "
        "is genuinely that nothing matches, say so explicitly and name where you "
        "looked — that is a valid result and will not be blocked again."
        % (atype or "subagent")
    ),
}))
PY
exit 0
