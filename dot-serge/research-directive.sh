#!/usr/bin/env bash
# Serge UserPromptSubmit hook — explicit-research directive ($0, no LLM).
#
# Why: the hard-task classifier routes research-shaped turns to the strong
# lane, but routing only picks the MODEL — nothing forces the METHOD. Observed
# 2026-07-20: "as per your deep research, who is the best soccer player" was
# answered from priors in one shot, dressed as "a consensus of statistical
# models, sports analysts, and peer accolades" — zero searches run. That is
# fabricated method attribution.
#
# Fix: when the user EXPLICITLY requests research (not merely a hard task),
# inject a directive the model cannot miss: run real searches (or /research)
# before answering, or say plainly that the answer is general knowledge with
# no live search behind it. Fires only on explicit research phrasing —
# ordinary hard-task routing stays the classifier's job.
#
# Off-switch: SERGE_RESEARCH_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_RESEARCH_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, re

# Harness plumbing is not a user turn. Strip <system-reminder> AND <task-notification>
# blocks (background-task completions arrive through UserPromptSubmit): 13 of 45 consults on
# 2026-07-21 fired on task notifications — wasted free-tier quota and added latency before
# every background completion. If nothing user-authored remains, this is not a turn to act on.
_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

prompt = str(d.get("prompt") or "")
prompt = re.sub(_WRAPPERS, " ", prompt, flags=re.S).strip()
if not prompt:
    sys.exit(0)

EXPLICIT_RESEARCH = re.compile(
    r"\b("
    r"deep[- ]?research"
    r"|(?:do|run|per(?:form)?) (?:some |a |your )?research"
    r"|research (?:this|that|it|the)\b"
    r"|as per your (?:deep )?research"
    r"|based on your (?:deep )?research"
    r"|look (?:it|this|that) up"
    r"|search the web"
    r"|/research"
    r")\b",
    re.IGNORECASE,
)

# Tier 2 — research-SHAPED questions that never say the word "research".
# The original regex only caught explicit phrasing, so the exact failure it was
# built to stop ("answered from priors, dressed as consensus") still happened
# whenever the user asked naturally: "what's the best X in 2026", "is Y still
# maintained", "A vs B". These are claims about the CURRENT WORLD, which priors
# cannot settle and a knowledge cutoff silently gets wrong.
RESEARCH_SHAPED = re.compile(
    r"\b("
    r"latest|newest|most recent|currently|current(?:ly)? (?:best|available)"
    r"|these days|right now|as of \d{4}|in 20\d\d|up[- ]to[- ]date"
    r"|still (?:maintained|supported|free|available|work(?:s|ing)?)"
    r"|deprecated|end[- ]of[- ]life|discontinued"
    r"|best (?:way|tool|option|provider|library|framework|model|practice)"
    r"|alternatives? to|compare[d]? (?:to|with)|vs\.?|versus"
    r"|which (?:is|one) (?:better|best)|who (?:is|are) the (?:best|top)"
    r"|how much does .* cost|pricing for|what changed in"
    r")\b",
    re.IGNORECASE,
)

# Suppressors: the same words appear constantly in ordinary coding turns
# ("best way to structure this function", "compare these two files"). When the
# prompt is anchored to LOCAL context, it is a code question, not a world
# question — firing there would burn quota and add latency for nothing.
LOCAL_CONTEXT = re.compile(
    r"\b("
    r"this (?:file|function|class|method|repo|code|script|test|error|bug)"
    r"|our (?:code|repo|codebase|implementation|setup)"
    r"|the (?:diff|stack ?trace|traceback|failing test)"
    r"|in (?:the )?(?:repo|codebase|project)"
    r"|\.(?:ts|tsx|js|jsx|py|go|rs|sh|json|yaml|yml|md)\b"
    r"|/[\w.-]+/[\w.-]+"
    r")",
    re.IGNORECASE,
)

explicit = bool(EXPLICIT_RESEARCH.search(prompt))
shaped = bool(RESEARCH_SHAPED.search(prompt)) and not LOCAL_CONTEXT.search(prompt)
if not (explicit or shaped):
    sys.exit(0)

# The method, not just the obligation. Honesty about whether a search ran was
# the original fix; it does not make the search GOOD. These are the steps that
# separate a real answer from a plausible one: decompose, query from several
# angles, reach the primary source rather than a summary of it, and treat
# disagreement between sources as a finding instead of noise.
METHOD = (
    "Method — do not skip steps:\n"
    "1. Decompose the question into the specific sub-claims that must each be true.\n"
    "2. Run SEVERAL searches from different angles, not one. Vary the wording; a "
    "single query returns one slice of the web.\n"
    "3. Open the primary source — the vendor's own docs, terms, changelog, repo, "
    "or filing. Aggregators, blog summaries and SEO pages restate things "
    "incorrectly and go stale. Quote what the primary source actually says.\n"
    "4. When sources disagree, say so and say which you trust and why. Do not "
    "average them into a confident middle.\n"
    "5. Separate what you VERIFIED from what you INFERRED, and name what you "
    "could not confirm. A known gap is a result; a masked gap is a defect.\n"
    "6. Cite the URLs you actually opened."
)

if explicit:
    ctx = (
        "<system-reminder>\n"
        "The user explicitly asked for RESEARCH. Ground the answer in live "
        "searches you actually run in this session. If for some reason no search "
        "is run, you MUST say plainly that the answer comes from general "
        "knowledge with no live research behind it. Never imply searches, "
        "sources, or a consensus you did not gather.\n\n" + METHOD + "\n"
        "</system-reminder>"
    )
else:
    ctx = (
        "<system-reminder>\n"
        "This question turns on the CURRENT state of the world (recency, "
        "pricing, comparisons, what is still maintained). Your training data is "
        "stale by construction and may be confidently wrong here. Search before "
        "answering, or state explicitly that you did not and that the answer is "
        "unverified general knowledge.\n\n" + METHOD + "\n"
        "</system-reminder>"
    )
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
