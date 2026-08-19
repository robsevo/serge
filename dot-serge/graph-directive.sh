#!/usr/bin/env bash
# Serge UserPromptSubmit hook — graph-engineering directive ($0, no LLM call).
#
# WHY: the layer above loops has no always-on path.
#
#   G. ORCHESTRATION. serge has an org graph already — ~/.serge/agents/*.md is 15 named
#      seats owning zones, and council.md is its routing/quota ladder. What it does NOT
#      have is a WORK graph step: nothing asks the driver to enumerate the jobs, name the
#      real dependency edges, and decide what each node must be TOLD, before it starts
#      spawning. So multi-specialist turns get seat-first improvisation ("send a scout and
#      see"), independent jobs get serialized because the roster is listed in an order, and
#      parallelism is chosen by feel. council.md covers the DELIBERATION shape (brief →
#      architect → reviewer) but not arbitrary multi-node work, and it is only loaded in
#      council mode — an ordinary "can you have a few agents do X" turn loads none of it.
#
#   E. EDGE LOSS. The measured failure mode of this layer: context does not cross a node
#      boundary unless an edge carries it. Subagents run memory-blind and CLAUDE.md-blind
#      by design, so an omitted fact doesn't raise — the downstream seat confidently builds
#      on information it never had. handoff.md exists as the carrier but nothing prompts the
#      pre-spawn check ("which ledger lines does this node need?"), and nothing names this
#      shape when the user reports it after the fact ("the reviewer didn't know about X").
#
# FIX: on an orchestration-shaped or edge-loss-shaped prompt, inject the corresponding
# procedure as a <system-reminder> so it is in front of the model AT the decision point —
# same mechanism and same benign-both-directions design as logic-directive.sh (a false
# positive costs a few tokens and better habits, never wrong behavior). No model call, no
# latency.
#
# Deliberately NOT triggered by the bare word "graph": that word is overwhelmingly charts,
# knowledge graphs, and dependency graphs on this box. Triggering is on orchestration
# SHAPE, not vocabulary.
#
# Complements: logic-directive.sh (boolean rigor) · ambiguity-directive.sh (intent decoding)
# · auto-consult.sh (hard-turn reasoning consult) · discovery-delegate.sh (scout routing).
# Full procedure: ~/.serge/skills/graph-engineering/SKILL.md
#
# Off-switch: SERGE_GRAPH_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_GRAPH_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, re

# Harness plumbing is not a user turn (same wrappers ambiguity/logic-directive strip).
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

# --- G: orchestration-shaped turn ---------------------------------------------
# Multi-node work is about to be structured. These are the turns where jobs, edges and
# briefs get improvised instead of drawn.
ORCH = re.compile(r"""
  \b(
    # multiple workers, explicitly
      (?:multi|multiple|several|few|couple\s+of|bunch\s+of|many|parallel|two|three|four|
         some)\s+
        (?:sub)?(?:agents?|specialists?|seats?|workers?|reviewers?|scouts?|models?)
    | (?:sub)?agents?\s+in\s+parallel
    | multi[-\s]agent | agent\s+swarm | swarm\s+(?:of|mode) | hive\s+mode
    | fan[-\s]?out | fan[-\s]?in
    # spawning / delegating
    | (?:spawn|dispatch|deploy|seat|convene|orchestrat\w+|coordinat\w+|delegat\w+)\s+
        [^.\n]{0,30}?\b(?:agents?|specialists?|seats?|workers?|subagents?|council|tasks?|jobs?)
    | (?:have|get|use|run)\s+(?:a\s+few|several|multiple|some|two|three)\s+
        [^.\n]{0,20}?\b(?:agents?|specialists?|seats?|do|work|handle|review)
    | council\s+(?:mode|deliberation|round) | tier\s*2\b
    # pipeline / staged workflow shape
    | (?:pipeline|workflow|work\s+graph|task\s+graph|org\s+graph|dag)\b
    | (?:stages?|phases?|steps?)\s+[^.\n]{0,25}?\b(?:in\s+parallel|depend|sequence|order|
                                                    handoff|hand\s+off)
    | hand[-\s]?off\w* | handoffs?
    # explicit parallelism decisions
    | (?:what|which|can\s+(?:we|i|you))\s+[^.\n]{0,30}?\b(?:run|go|be\s+done)\s+in\s+parallel
    | (?:in\s+parallel|concurrently|at\s+the\s+same\s+time)\s+
        [^.\n]{0,30}?\b(?:agents?|specialists?|jobs?|tasks?|reviews?|scouts?)
    | (?:parallelize|parallelise)\w*
    # routing decisions
    | who\s+(?:should|would|does)\s+[^.\n]{0,25}?\b(?:do|handle|own|review|take|write|build)
    | (?:which|what)\s+(?:agent|specialist|seat|model)\s+(?:should|would|for)
  )\b
""", re.I | re.X)

# --- E: edge-loss-shaped turn -------------------------------------------------
# A node acted without a fact it needed, or the user is reporting the symptom of it.
# NOT a bare failure report — this class is specifically about information not crossing
# a boundary between workers/steps.
EDGE = re.compile(r"""
  \b(
      (?:didn'?t|did\s+not|doesn'?t|does\s+not|never)\s+know\s+about
    | (?:wasn'?t|was\s+not|isn'?t|is\s+not)\s+(?:told|given|passed|aware\s+of)
    | (?:lost|losing|loses|missing|dropped|drops)\s+
        [^.\n]{0,25}?\b(?:context|information|info|state|the\s+thread|details?)
    | context\s+(?:loss|isn'?t|is\s+not|doesn'?t|does\s+not|never)\s*
        [^.\n]{0,20}?(?:carr\w+|cross\w*|reach\w*|flow\w*|pass\w*|shared?)
    # Past tense matters here — the symptom is usually reported after the fact
    # ("the subagent never SAW the failing test"), not in the present.
    | (?:the\s+)?(?:agent|subagent|specialist|reviewer|scout|architect|seat|worker)\s+
        [^.\n]{0,30}?\b(?:didn'?t|did\s+not|doesn'?t|never|wasn'?t|was\s+not)\s+
        [^.\n]{0,20}?\b(?:know|knew|known|see|saw|seen|have|had|get|got|receive|received|
                          told|hear|heard|aware|read)
    | (?:duplicat\w+|repeat\w+|redid|redoing|re-?do(?:ing)?|same)\s+
        [^.\n]{0,25}?\b(?:work|search|findings?|effort)
    | (?:brief|briefing)\s+[^.\n]{0,25}?\b(?:missing|omitted|incomplete|didn'?t\s+include)
    | (?:agents?|specialists?|seats?)\s+[^.\n]{0,25}?\b(?:stepped\s+on|conflict\w*|overlap\w*)
    | out\s+of\s+sync\s+[^.\n]{0,20}?\b(?:agents?|specialists?|nodes?|seats?)
  )\b
""", re.I | re.X)

hit_g = bool(ORCH.search(clean))
hit_e = bool(EDGE.search(clean))
if not (hit_g or hit_e):
    sys.exit(0)

ctx = "<system-reminder>\n"
if hit_g:
    ctx += (
        "GRAPH ENGINEERING — this turn is about to structure work across more than one "
        "node. Loops program one agent's behavior; this is the layer that programs the "
        "organization, and its failure mode is silent. Before you spawn anything:\n"
        "0. GATE FIRST — is the path knowable up front? If this is open-ended research or "
        "discovery-driven debugging where each step depends on what the last one found, do "
        "NOT pre-draw a graph: run ONE agentic loop with a real stop condition and "
        "structure afterward. (LangChain built deep research on a graph and migrated off "
        "it: planning and delegation shouldn't be hardcoded when the path must be "
        "discovered.) Only draw the graph when the shape is genuinely knowable.\n"
        "1. JOBS, NOT SEATS — list the actual units of work first ('map every call site of "
        "X', not 'a scout'). Two jobs that would return the same finding are one job. "
        "Assign seats to jobs afterward, or the task ends up shaped like the roster "
        "instead of the problem.\n"
        "2. DEPENDENCY EDGES — for each job name what must finish first AND WHY. No stated "
        "reason = not a real dependency = it runs in parallel. Two jobs run in parallel iff "
        "neither is on the other's dependency path and their scopes don't overlap.\n"
        "3. CONTEXT EDGES — for each job, write down what it must be TOLD: which prior "
        "findings, file:line refs, constraints, and FAILED ATTEMPTS ride its brief. A "
        "subagent is memory-blind and CLAUDE.md-blind; the brief is its entire world. Carry "
        "the relevant handoff.md ledger lines — the relevant ones, not the whole ledger.\n"
        "   IF YOU HAVE NOT LOOKED YET, LOOK BEFORE YOU BRIEF. The constraint that makes a "
        "brief wrong usually lives in the environment, not in the conversation: deploy and "
        "ops notes, resource ceilings (RAM/connections/rate limits), ports already taken, "
        "the test runner and conventions actually in use, and the config the code really "
        "reads. A technically excellent brief that omits the one limit the work would "
        "violate is the DEFAULT failure of this step, not an edge case — decomposing the "
        "work is the easy half, and it is not the half that fails.\n"
        "4. FAILURE RULE PER NODE — decide now: retry / fallback seat / escalate to a "
        "different stronger lane / abort the branch. Two failures by one seat on the same "
        "job means the approach or the seat is wrong, and the third attempt must open with "
        "the post-mortem of both.\n"
        "5. RETURN SHAPE — state the exact output expected per node (fields, format, "
        "whether file:line evidence is required), or fan-in degrades into re-reading raw "
        "dumps. At fan-in, surface genuine disagreement instead of averaging it; two nodes "
        "agreeing off the same incomplete brief is one error twice.\n"
        "Full procedure: ~/.serge/skills/graph-engineering/SKILL.md — load it if this is "
        "more than a two-node task.\n"
    )
if hit_e:
    if hit_g:
        ctx += "\n"
    ctx += (
        "EDGE LOSS — this looks like the signature failure of multi-node work: CONTEXT DOES "
        "NOT CROSS A NODE BOUNDARY UNLESS AN EDGE CARRIES IT. A subagent runs memory-blind "
        "and CLAUDE.md-blind, so an omitted fact never raises an error — the seat "
        "confidently produces work built on information it never had. Diagnose in this "
        "order:\n"
        "1. MISSING CONTEXT EDGE (usually the answer) — name the specific fact and the "
        "specific node that acted without it. Then name the edge that should have carried "
        "it.\n"
        "2. WRONG RETURN SHAPE — did a node return something the synthesis step silently "
        "dropped because it didn't match what was expected?\n"
        "3. FALSE DEPENDENCY / SCOPE OVERLAP — was work serialized that was independent, or "
        "did two nodes re-find the same thing because their scopes weren't partitioned?\n"
        "4. UNBOUNDED CYCLE — did a seat retry the same failed approach instead of "
        "escalating to a different lane?\n"
        "FIX THE LEDGER, NOT JUST THIS TURN: append the load-bearing decisions to handoff.md "
        "as 2-4 attributed lines, and before every future spawn ask 'which ledger lines does "
        "this node need, and which does it not?'. Dumping the whole ledger is as bad as an "
        "empty one — the signal gets buried in noise the node didn't need.\n"
    )
ctx += "</system-reminder>"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
