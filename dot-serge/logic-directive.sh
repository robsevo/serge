#!/usr/bin/env bash
# Serge UserPromptSubmit hook — logic-rigor + ingenuity directive ($0, no LLM call).
#
# WHY: two capability gaps that neither existing prompt hook covers.
#
#   L. LOGIC. ~/.serge/skills/logic exists (logic_check.py — equiv/sat/taut/implies,
#      deterministic, counterexample-printing) and is referenced from the AGENT files
#      (debugger/reviewer/architect/…) and deliberate.md. But an ordinary main-thread turn
#      never loads an agent file, so on "why does this guard never fire?" the driver
#      hand-evaluates the boolean — the exact thing the skill's own evidence note says
#      models are measurably BAD at (Logic-LM / LINC: translate-then-solve beats
#      reason-about-logic). The tool being installed is not the tool being used.
#      auto-consult.sh does not close it either: its hard-turn regex is architecture /
#      concurrency / security vocabulary — no boolean, branch, equivalence or
#      dead-code terms — so logic turns get neither the consult nor the tool.
#
#   I. INGENUITY. The measured failure is re-applying a failed approach harder: the
#      driver commits to the first workable idea, and when it fails, patches the patch.
#      Nothing in the always-on path asks for a second ANGLE (different layer, inverted
#      causality, dissolving the requirement instead of satisfying it) before it commits.
#
# FIX: on a logic-shaped or stuck-shaped prompt, inject the corresponding procedure as a
# <system-reminder> so it is in front of the model AT the decision point — same mechanism
# and same benign-both-directions design as ambiguity-directive.sh (a false positive costs
# a few tokens and better habits, never wrong behavior). No model call, no latency.
#
# Complements: research-directive.sh (method honesty) · ambiguity-directive.sh (intent
# decoding) · auto-consult.sh (hard-turn reasoning consult).
#
# Off-switch: SERGE_LOGIC_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_LOGIC_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, re

# Harness plumbing is not a user turn (same wrappers ambiguity-directive.sh strips).
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

# --- L: logic-shaped turn -----------------------------------------------------
# Boolean/branch reasoning, equivalence claims, reachability, "this condition looks
# right but behaves wrong". These are the turns where hand-evaluation quietly fails.
LOGIC = re.compile(r"""
  \b(
      (?:never|always)\s+(?:fires?|firing|runs?|triggers?|executes?|matches?|true|false|hits?|
                          gets?\s+(?:hit|called|run))
    | (?:dead|unreachable|impossible)\s+(?:code|branch|branches|path|case|else)
    | truth\s+table | tautolog\w* | contradiction | satisfiab\w* | de\s*morgan
    # "equivalent" needs a comparison context — "iOS has no equivalent app
    # capability" is not a logic turn.
    | (?:logically|semantically|functionally|behaviou?rally)\s+equivalen\w*
    | equivalen\w*\s+(?:to\s+(?:the|this|that|each)|conditions?|expressions?|guards?|predicates?)
    | (?:are|is)\s+(?:these|those|they|the\s+two|both)\b[^.\n]{0,40}?equivalen\w*
    | short[-\s]?circuit\w*
    | (?:boolean|bool)\s+(?:logic|expression|condition|flag)
    | (?:condition|conditional|guard|predicate|branch|if[-\s]statement|else[-\s]if)
        [^.\n]{0,40}?\b(?:wrong|inverted|backwards|never|always|weird|off|broken|
                           right\s+but|looks\s+right|should\s+be)
    | (?:wrong|inverted|backwards|flipped|negated)\s+
        (?:condition|conditional|guard|logic|predicate|comparison|check)
    | logic\s+(?:bug|error|is\s+wrong|seems\s+wrong|doesn'?t|does\s+not)
    | (?:invariant|precondition|postcondition|implies|implication)
    | off[-\s]by[-\s]one
    # Refactor targets must be genuinely conditional — a bare "if" or "logic"
    # matches "merge if that makes sense" / "simplified the OCR logic".
    | (?:refactor|simplif\w+|flatten|collapse|merge|split)\s+
        [^.\n]{0,30}?\b(?:conditions?|conditionals?|guards?|predicates?|
                            if[-\s](?:statement|block|chain)|if/else|nested|boolean)
    | nested\s+(?:if|ifs|conditional|conditionals|ternar\w+)
  )\b
""", re.I | re.X)

# --- I: ingenuity-shaped turn -------------------------------------------------
# The obvious approach has already failed, or the user is explicitly asking for a
# better idea. NOT a bare failure report ("it's broken") — ambiguity-directive.sh
# G5 owns that; this class is about repetition and exhausted options.
INGENUITY = re.compile(r"""
  \b(
      tried\s+(?:everything|it\s+all|that\s+already|already|several|multiple|many)
    | (?:keeps?|still)\s+(?:happening|failing|breaking|coming\s+back|doing\s+(?:it|that|this))
    | same\s+(?:error|issue|problem|bug|thing)\s+(?:again|as\s+before|keeps)
    | (?:third\s+time|second\s+time|over\s+and\s+over)\b[^.\n]{0,20}\b(?:fail\w*|broke\w*|error)
    | (?:better|smarter|cleverer|another|different|other|simpler|more\s+elegant)\s+
        (?:way|approach|angle|idea|option|options|solution|design)
    | (?:any|some)\s+other\s+(?:way|ideas?|options?|approach)
    | is\s+there\s+a\s+way\s+to
    | work\s?around | hack\s+around | get\s+around\s+(?:this|it|that)
    # "stuck" must describe a person, not a thing ("TSN1 stuck at 1 source").
    | (?:i'?m|im|we'?re|are\s+you|you)\s+stuck\b | stuck\s+on\b | stuck\?
    | can'?t\s+figure\s+(?:it\s+)?out | no\s+idea\s+why
    | makes?\s+no\s+sense | shouldn'?t\s+be\s+possible | doesn'?t\s+make\s+sense
    | (?:this|that|it)\s+is\s+(?:bizarre|baffling|inexplicable)
    | think\s+(?:harder|outside|creatively|laterally)
    | be\s+(?:creative|ingenious|inventive|clever)
  )\b
""", re.I | re.X)

hit_l = bool(LOGIC.search(clean))
hit_i = bool(INGENUITY.search(clean))
if not (hit_l or hit_i):
    sys.exit(0)

ctx = "<system-reminder>\n"
if hit_l:
    ctx += (
        "LOGIC RIGOR — this turn involves boolean/branch reasoning, which you are measurably "
        "bad at by inspection (translate-then-solve beats reason-about-logic). Do NOT "
        "hand-evaluate it and do NOT assert two conditions are equivalent because they look "
        "equivalent. Instead:\n"
        "1. NAME the atomic predicates: rewrite each real expression with bare names "
        "(`user.age >= 18` → `adult`) and keep the legend, so a counterexample maps back to "
        "real code.\n"
        "2. RUN the deterministic checker — `python3 ~/.serge/skills/logic/logic_check.py` "
        "with `equiv \"<before>\" \"<after>\"` (refactor safety), `sat \"<guard>\"` (can this "
        "branch EVER fire? UNSAT = dead code), `taut \"<guard>\"` (always true = dead else), "
        "`implies \"<premise>\" \"<conclusion>\"`, or `table \"<expr>\"` for ≤4 vars. Exit 0 "
        "holds, 2 fails with a counterexample, 1 rejects the input.\n"
        "3. TREAT THE COUNTEREXAMPLE AS THE ANSWER. NOT-EQUIVALENT means your reading was "
        "wrong, not the tool's — trace that exact row through the real code before you "
        "conclude anything.\n"
        "4. Check EVERY branch for reachability before you ship a refactor, and say which "
        "rows changed behavior if any did.\n"
        "The full workflow and the debugging-fallacy checklist are in "
        "~/.serge/skills/logic/SKILL.md — load it if this is more than a single expression.\n"
    )
if hit_i:
    if hit_l:
        ctx += "\n"
    ctx += (
        "INGENUITY — the obvious approach is exhausted, suspect, or explicitly not wanted. "
        "Do not re-apply a failed fix harder, and do not settle on the first thing that could "
        "work. Before you commit:\n"
        "1. STATE THE MECHANISM you believe produces the observed behavior, in one line — the "
        "causal chain, not the symptom. If you cannot state it, you are guessing; go get the "
        "evidence that would let you state it.\n"
        "2. PRODUCE A SECOND, GENUINELY DIFFERENT ANGLE before choosing — a different layer "
        "(config/runtime/build/environment rather than application code), inverted causality "
        "(what if the thing you assume is the effect is the cause?), or DISSOLVING the "
        "requirement instead of satisfying it. Two angles, then pick on merit in one line and "
        "say why the other loses.\n"
        "3. PREFER THE FIX THAT MAKES THE FAILURE IMPOSSIBLE over one that handles it. A guard "
        "around a bad state is worse than a design where the bad state cannot occur.\n"
        "4. HUNT THE SLACK IN THE CONSTRAINTS: name the one assumption that, if relaxed, "
        "dissolves the problem — then say whether it is actually fixed or merely assumed. "
        "Constraints inherited from a previous attempt are the usual culprits.\n"
        "5. If an earlier attempt failed, say WHY it failed before proposing the next one. "
        "'Try the same thing more carefully' is not a next attempt.\n"
    )
ctx += "</system-reminder>"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
