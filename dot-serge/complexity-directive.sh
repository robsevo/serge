#!/usr/bin/env bash
# Serge UserPromptSubmit hook — complexity budget + volume discipline ($0, no LLM call).
#
# WHY: algo-gate.sh prices code AFTER it exists, which is the right place to catch a
# mistake but the wrong place to prevent one. The cheapest O(n²) is the one never
# written: the choice that decides it — "what is n, and what container makes this
# lookup O(1)?" — happens BEFORE the first line, and nothing in the always-on path
# asks for it. auto-consult.sh does not close this either; its hard-turn regex is
# architecture/concurrency/security vocabulary, with no complexity, data-structure,
# or throughput terms.
#
# Two classes, deliberately narrow:
#   C. COST — the turn is about an algorithm, a hot path, scale, or a query. Inject
#      the budget procedure: state n, state the target, name the structure, THEN code.
#   V. VOLUME — the user is asking for less code, or reacting to bloat. Inject the
#      subtraction procedure, because "improve this" reliably produces MORE lines.
#
# Same mechanism and same benign-both-directions design as logic-directive.sh: a
# false positive costs a few tokens and better habits, never wrong behavior.
#
# Off-switch: SERGE_COMPLEXITY_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_COMPLEXITY_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
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

# --- C: cost-shaped turn ------------------------------------------------------
# Algorithms, hot paths, scale, and the backend shapes where the cost is round
# trips rather than CPU. "slow"/"performance" need a technical neighbour so a
# "slow morning" or "performance review" does not trip it.
COST = re.compile(r"""
  \b(
      big[-\s]?o\b | complexity | asymptotic | o\(n | quadratic | linear\s+scan
    | algorithm\w* | data\s?structure\w*
    | (?:binary|linear)\s+search | (?:sort|sorting|dedup\w*|group[-\s]?by|join)\s+
        [^.\n]{0,25}?\b(?:list|array|rows?|records?|items?|users?|entries|data|set|table)
    | n\s*\+\s*1\b | (?:batch|bulk)\s+(?:the\s+)?(?:quer\w+|fetch\w*|insert\w*|request\w*)
    # The neighbour must be a technical noun. Bare `it`/`this` here matched
    # "sorry for the slow reply this morning" — so the pronoun forms are spelled
    # out separately as fixed phrases instead.
    | (?:slow|fast|speed\s?up|optimi[sz]\w+|perf\w*|latency|throughput|bottleneck|
       hot\s?path|expensive|efficient\w*)\s*
        [^.\n]{0,30}?\b(?:quer\w+|endpoint|api|loop|function|request|handler|page|
                          render|scan|index|cache|job|worker|route|service|call|
                          fetch|algorithm|code)
    | (?:speed|slow)s?\s+(?:it|this|that|things)\s+(?:up|down)
    | (?:quer\w+|endpoint|api|loop|function|request|handler|job|worker|route|service)
        [^.\n]{0,30}?\b(?:is\s+slow|too\s+slow|slows?\s+down|times?\s+out|timing\s+out|
                          takes\s+(?:forever|ages|too\s+long)|hangs?)
    | (?:scale|scales?|scaling)\s+(?:to|up|with|badly|poorly|linearly)
    | (?:million|billion|thousands?|100k|1m)\s+(?:of\s+)?(?:rows?|records?|users?|items?|
                                                            entries|requests?|files?)
    | (?:large|huge|big|massive)\s+(?:dataset|data\s?set|table|collection|list|array|file)
    | memory\s+(?:leak|blow|usage|footprint) | out\s+of\s+memory | oom\b
    | (?:cache|caching|index|indexing|indexes|indices)\s+(?:this|it|the|a|on)\b
    # "make the report faster" puts the trigger AFTER the noun, so the noun-first
    # branches above never see it.
    | (?:make|making|made|get|getting)\s+[^.\n]{0,25}?\b(?:faster|quicker|cheaper|snappier)
  )\b
""", re.I | re.X)

# --- B: build-shaped turn -----------------------------------------------------
# The COST class fires when someone has ALREADY noticed slowness. This one fires
# when serge is about to WRITE code over a collection — the moment the complexity
# is actually decided. A quadratic loop is cheapest to prevent, and the prevention
# is a single sentence stated before the first line.
BUILD = re.compile(r"""
  \b(?:
      (?:write|add|implement|build|create|refactor|rewrite|extract|port|wire\s?up)\s+
        [^.\n]{0,45}?\b(?:endpoint|api|route|handler|service|worker|job|queue|cron|
                          parser|loader|resolver|controller|repositor\w+|
                          quer\w+|migration|schema|index|cache|
                          function|method|module|script|algorithm|
                          loop|filter|sort|search|dedup\w*|aggregat\w*|group|join|merge|
                          list|array|map|set|dict|table|batch|pipeline|report|export)
    | for\s+each\s+(?:of\s+)?(?:the\s+)?\w+
    | (?:iterate|loop)\s+(?:over|through|across)
    | (?:go|run)\s+through\s+(?:all|each|every|the\s+list|the\s+rows)
    | (?:process|handle|fetch|load|enrich|match|combine|reconcile)\s+
        (?:all|each|every|the)\s+\w+
  )\b
""", re.I | re.X)

# --- V: volume-shaped turn ----------------------------------------------------
# The user wants LESS code. This is the class where "improve it" produces more.
VOLUME = re.compile(r"""
  \b(
      (?:too\s+much|too\s+many)\s+(?:code|lines|abstraction|layers|files)
    | (?:bloat\w*|over[-\s]?engineer\w*|convoluted|verbose|boilerplate)
    | (?:simplif\w+|slim|trim|shrink|shorten|tighten|condense|streamline|reduce)\s+
        [^.\n]{0,30}?\b(?:code|it|this|that|function|module|file|implementation|logic|thing)
    | (?:make|keep)\s+(?:it|this|that)\s+(?:shorter|smaller|simpler|leaner|tighter|minimal)
    | (?:fewer|less)\s+(?:lines|code|abstraction|layers|indirection)
    | (?:dead|unused|redundant|duplicate[d]?)\s+(?:code|function|variable|import|branch)
    | (?:clean|tidy)\s?up\s+(?:the\s+)?(?:code|this|it|that|file|function)
    | do(?:es)?n'?t\s+need\s+(?:all\s+)?(?:that|this|these)\b
  )\b
""", re.I | re.X)

# --- planning / brainstorming ------------------------------------------------
# Volume discipline is about SHIPPED CODE, never about thinking. A plan or a
# brainstorm should be detailed — that is where the expensive decisions get made,
# and a terse plan is how you get a confident wrong one. So on a planning turn the
# VOLUME class is suppressed entirely and the budget text explicitly asks for depth;
# the subtraction happens later, when there is real code to subtract from.
PLANNING = re.compile(r"""
  \b(
      plan(?:ning|s)?\b | brainstorm\w* | design\s+(?:doc|a|the|this|an)
    | (?:think|reason)\s+(?:through|about|it\s+through)
    | (?:explore|consider|weigh|compare)\s+[^.\n]{0,30}?\b(?:options?|approaches?|
                                                            alternatives?|tradeoffs?|designs?)
    | (?:what|which|how)\s+(?:are\s+the\s+)?(?:options?|approaches?|tradeoffs?)
    | how\s+should\s+(?:we|i|you)\b | what'?s\s+the\s+best\s+way
    | before\s+(?:we|you)\s+(?:code|build|implement|write)
    | (?:pros|cons)\s+and\s+(?:cons|pros) | tradeoffs?\b
    | architecture | rfc\b | spec(?:ification)?\b
  )\b
""", re.I | re.X)

planning = bool(PLANNING.search(clean)) or str(d.get("permission_mode") or "") == "plan"

hit_c = bool(COST.search(clean))
hit_b = bool(BUILD.search(clean)) and not hit_c   # COST already carries the full text
hit_v = bool(VOLUME.search(clean)) and not planning
if not (hit_c or hit_b or hit_v):
    sys.exit(0)

ctx = "<system-reminder>\n"
if hit_b:
    ctx += (
        "COMPLEXITY BUDGET — you are about to write code over a collection, which is where "
        "the cost gets decided. Before the first line, state in ONE line: what n is and its "
        "realistic size, and the Big-O you are targeting. Then hold to it:\n"
        "- The accidental O(n²) is always the same shape — a linear lookup inside a loop "
        "(`.find` / `.includes` / `.indexOf` / `x in list` / a repeated query). Build the "
        "index ONCE before the loop (dict / set / Map), then look up in O(1).\n"
        "- A query or `await` inside a loop is N round trips no matter how fast the code is. "
        "Batch it, or gather independent iterations concurrently with a bounded limit.\n"
        "- Check the loop at three boundaries: empty, exactly one, exactly at the limit. "
        "Decide whether the limit is IN or OUT and use the SAME operator everywhere.\n"
        "- Then verify rather than assert: `python3 ~/.serge/skills/complexity/algo_check.py "
        "all <file>` and cite it. State the complexity you SHIPPED in your summary.\n"
    )
if hit_c:
    ctx += (
        "COMPLEXITY BUDGET — this turn touches an algorithm or a hot path. Model-written "
        "code is measurably bulkier than an engineer's for the same behavior, and bulk shows "
        "up at runtime as extra passes, extra copies, and extra round trips. Decide the cost "
        "BEFORE you write the loop, not after:\n"
        "1. NAME n. Say what actually grows — rows, users, files, requests — and its realistic "
        "size. A different n changes the right answer: O(n²) on 20 items is correct and "
        "simple; on 100k it is an outage.\n"
        "2. STATE THE TARGET in Big-O, and the cost of the obvious version, before coding. "
        "Write it in one line (`target O(n log n); naive nested scan is O(n²)`).\n"
        "3. NAME THE STRUCTURE that buys it. Nearly every accidental O(n²) is a linear lookup "
        "inside a loop — `.find` / `.includes` / `.indexOf` / `x in list` / a repeated query. "
        "Pre-index into a dict/set/Map ONCE before the loop and the lookup is O(1).\n"
        "4. COUNT ROUND TRIPS SEPARATELY from CPU. A query or `await` inside a loop is N+1: "
        "the latency is N × RTT no matter how fast the code is. Batch it, or gather the "
        "independent iterations concurrently.\n"
        "5. CHECK THE THREE BOUNDARIES on every loop you write — empty input, exactly one "
        "element, and exactly at the limit. Off-by-one lives at the third one, and it is the "
        "defect class model-written code carries most.\n"
        "6. IF THE COST IS TOO HIGH, CHANGE THE ALGORITHM — do not patch it. Adding a cache, "
        "an early return, or a guard in front of a linear scan leaves the exponent exactly "
        "where it was (a memo cache over distinct keys is still O(n²)). Pick the technique "
        "that fits the SHAPE: lookup-in-a-loop → index once into a dict/Map (O(n·m)→O(n+m)); "
        "pairs/duplicates/closest → sort once then one pass or two pointers (→O(n log n)); "
        "contiguous window → sliding window (→O(n)); repeated range sums → prefix sums; "
        "top-k → a heap of size k; overlapping subproblems → memo/bottom-up DP; a query per "
        "item → ONE batched query. If the cost is already at the problem's lower bound (you "
        "must read every element; comparison sort cannot beat n log n), SAY THAT — naming the "
        "lower bound is a complete answer.\n"
        "7. VERIFY, DO NOT ASSERT. Run the deterministic checker on what you wrote:\n"
        "   `python3 ~/.serge/skills/complexity/algo_check.py all <file>`\n"
        "   It prices each function (with the evidence chain that produced the exponent) and "
        "flags boundary slips. Cite what it said, and after a fix confirm the exponent ACTUALLY "
        "DROPPED — an unchanged exponent means you patched it, not fixed it. Do not claim a "
        "complexity you did not check; if you disagree with it, say why in one line — it is a "
        "syntactic estimate and it can be wrong. Method: ~/.serge/skills/complexity/SKILL.md\n"
    )
if hit_v:
    if hit_c:
        ctx += "\n"
    ctx += (
        "VOLUME — the ask is for LESS code. The default failure here is answering a "
        "simplification request with a rewrite that is longer than what it replaced. "
        "Subtraction is the deliverable:\n"
        "1. MEASURE FIRST, then measure after. Line counts before and after, stated plainly. "
        "If the count went up, you did not simplify — say so instead of claiming you did.\n"
        "2. DELETE BEFORE YOU REWRITE. Dead variables, unused parameters, a wrapper that only "
        "forwards, a try/except that re-raises unchanged, `if c: return True else: return "
        "False`, comments that restate the line below them. Run "
        "`python3 ~/.serge/skills/complexity/algo_check.py fluff <file>` — it reports removable "
        "lines with the specific move for each.\n"
        "3. KEEP BEHAVIOR IDENTICAL unless asked otherwise, and say how you know — the test, "
        "the run, the equivalence check. Deleting a branch you did not prove dead is not "
        "simplification, it is a bug.\n"
        "4. NO NEW ABSTRACTION to make something shorter. A helper used once is indirection, "
        "not reuse; it moves lines rather than removing them.\n"
        "5. RESIST RESTORING what you removed. If a guard looks missing, check whether the "
        "caller already guarantees it before adding it back.\n"
    )
if planning and (hit_c or hit_b):
    ctx += (
        "\nSCOPE — this is a PLANNING/BRAINSTORMING turn, so go into DETAIL here. Work the "
        "complexity out properly: name n, price the candidate approaches against each other, "
        "say what each costs and where it breaks, and name the one you would reject and why. "
        "Depth is the deliverable at this stage — the decision you make now is the expensive "
        "one, and a thin plan is how a confident wrong design gets built. The brevity rule is "
        "about SHIPPED CODE, not about thinking: trim volume later, when there is real code to "
        "trim, not from this analysis.\n"
    )
ctx += "</system-reminder>"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
