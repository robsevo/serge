#!/usr/bin/env bash
# Serge UserPromptSubmit hook — documentation craft directive ($0, no LLM call).
#
# WHY (user report, 2026-08-15): "serge will sometimes just assume things are
# done. i had to ask him twice to re write the readme. and i had to ask him to
# deeply research first what a readme is."
#
# Three separate failures in one turn, and none of them had anything watching:
#
#   1. NO GENRE. Asked for a README, the model wrote *some prose about the
#      project*. A README is a genre with a known contract — what it is, why it
#      exists, how to install it, the smallest thing that actually runs — and a
#      model that never states that contract cannot hit it. The user had to
#      supply the missing step by hand ("research what a readme is"), which is
#      the step that should never have needed asking.
#   2. SKELETON FIRST, DEPTH ON DEMAND. The first pass came back thin, and depth
#      only arrived after the user pushed. That turns one turn into three and
#      puts the burden of quality control on the person who asked.
#   3. UNGROUNDED CLAIMS. Docs are the one artifact where every sentence is a
#      factual claim about the repo — this command exists, this path exists,
#      this is how you install it — and prose is the one artifact where nothing
#      fails when the claim is false. Code that lies gets an exception; a README
#      that lies just sits there.
#
# Why a hook and not prose in the constitution: CONSTITUTION.md already carries
# the general "verify before claiming" line, and the workhorse seat still shipped
# a thin, ungrounded README. A general rule read every turn loses to a specific
# procedure delivered at the moment of the request. Same mechanism and same
# benign-both-directions design as complexity-directive.sh: a false positive
# costs a few hundred tokens and better habits, never wrong behavior.
#
# Enforcement partner: doc-reality-gate.sh checks the commands and paths this
# directive asks for AFTER the doc is written, so rule 3 is not on the honor
# system. The stop-side partner is check 3b in continue-on-unfinished.sh, which
# refuses an unverified done-claim over a doc edit.
#
# Cost: zero tokens on every turn that is not about writing documentation.
# Off-switch: SERGE_DOCS_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_DOCS_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
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

# --- Trigger -----------------------------------------------------------------
# A documentation ARTIFACT plus an intent to PRODUCE one. Both halves are
# required: "read the readme" is not a writing turn, and "write the parser" is
# not a documentation turn.
ARTIFACT = re.compile(r"""
  \b(
      readme(?:\.md)? | contributing(?:\.md)? | changelog(?:\.md)?
    | code\s+of\s+conduct | man\s?page
    | docs? | documentation | doc\s?site | docstrings?
    | api\s+(?:docs?|documentation|reference)
    | (?:user|dev(?:eloper)?|style|migration|upgrade|integration)\s+guide
    | getting[-\s]started | quick\s?start | onboarding\s+(?:doc|guide|page)
    | install(?:ation)?\s+(?:doc|docs|guide|instructions|steps)
    | usage\s+(?:doc|docs|guide|instructions)
    | tutorial | walkthrough | write[-\s]?up
  )\b
""", re.IGNORECASE | re.VERBOSE)

PRODUCE = re.compile(r"""
  \b(
      writ(?:e|ing) | re-?writ(?:e|ing) | redo | rewrote
    | updat(?:e|ing) | revis(?:e|ing) | rework(?:ing)?
    | improv(?:e|ing) | expand(?:ing)? | flesh(?:ing)?\s+out | beef(?:ing)?\s+up
    | creat(?:e|ing) | mak(?:e|ing) | generat(?:e|ing) | draft(?:ing)?
    | author(?:ing)? | add(?:ing)? | fill(?:ing)?\s+(?:in|out)
    | polish(?:ing)? | clean(?:ing)?\s+up | tidy(?:ing)?\s+up
    | fix(?:ing)? | overhaul(?:ing)? | consolidat(?:e|ing)
    | document(?:ing)?
  )\b
""", re.IGNORECASE | re.VERBOSE)

# "document the api endpoints" names no artifact noun, but documenting IS the
# artifact. The lookbehinds keep the NOUN sense out ("this document the api uses",
# "a document the team wrote") — only the imperative verb counts.
DOCUMENT_VERB = re.compile(
    r"(?<!\ba )(?<!\ban )(?<!\bthe )(?<!\bthis )(?<!\bthat )(?<!\beach )(?<!\bevery )"
    r"\bdocument(?:ing)?\s+(?:the\s+|this\s+|these\s+|our\s+|all\s+|its\s+|their\s+)?\w",
    re.IGNORECASE,
)

if not ((ARTIFACT.search(clean) and PRODUCE.search(clean))
        or DOCUMENT_VERB.search(clean)):
    sys.exit(0)

is_readme = re.search(r"\breadme\b", clean, re.IGNORECASE) is not None

ctx = (
    "<system-reminder>\n"
    "DOCUMENTATION CRAFT — this turn produces a document, so the document is the "
    "deliverable, not a sketch of one. Work the procedure below BEFORE writing the "
    "first line.\n\n"

    "1. NAME THE GENRE AND ITS CONTRACT, out loud, before writing. Every document "
    "type has a known job and a known set of sections readers expect to find. State "
    "which sections this one owes and who is reading it (a stranger who just found "
    "the project? a contributor? your future self?). A document written without "
    "naming its contract is a pile of true sentences in no useful order.\n\n"

    "2. READ THE EXISTING FILE IN FULL FIRST — the whole thing, not a head -50. It "
    "may contain hand-written material nobody wants destroyed, project-specific "
    "framing you cannot reconstruct, or decisions you would silently reverse. "
    "Rewriting is EDITING what is there; replacing a file you did not read is data "
    "loss with good intentions. If you are dropping a section, say which and why.\n\n"

    "3. GROUND EVERY CLAIM IN THE REPO, NOT IN MEMORY. Docs are the one artifact "
    "where every sentence is a factual claim and NOTHING fails when the claim is "
    "false — a wrong install command sits there looking correct forever. Before you "
    "write them, go read: the manifest (package.json / pyproject.toml / Cargo.toml) "
    "for the REAL script names, the entry point for how it actually starts, the "
    "config/env files for the REAL variable names, and the test command that really "
    "runs. Every command you print must be one you found in this repo. Every path "
    "you name must be one you saw in a tool result. Where it is cheap, RUN the "
    "command you are about to document and report what it did.\n\n"

    "4. FIRST PASS IS THE FINAL PASS. Do not hand back an outline, a skeleton, or a "
    "'starting point' expecting to be asked for depth — being asked twice for the "
    "same document is a defect, not a workflow. Write it complete the first time.\n\n"

    "5. SHOW, DON'T ASSERT. Replace adjectives with artifacts: a runnable command "
    "instead of 'easy to install', a real example with real output instead of "
    "'flexible', a diagram or a table where structure is the point. Cut every "
    "sentence that would still be true of a different project.\n\n"

    "6. BEFORE CLAIMING IT IS DONE, re-read the file you just wrote, end to end, as "
    "the reader. Then say what you actually verified and what you did not. "
    "'Rewrote the README' is not a report; 'rewrote it, ran the three documented "
    "commands, the install step is unverified because it needs a clean machine' is.\n"
)

if is_readme:
    ctx += (
        "\nREADME CONTRACT — a README answers, in this order, for someone who has "
        "never seen the project:\n"
        "  a. WHAT IS IT — one sentence, concrete, no marketing. Name the thing and "
        "what it does.\n"
        "  b. WHY IT EXISTS — the problem it solves, or what it replaces.\n"
        "  c. REQUIREMENTS — runtime/OS/accounts/keys needed, with versions.\n"
        "  d. INSTALL — exact copy-pasteable commands, in order, that you verified "
        "exist.\n"
        "  e. QUICKSTART — the SMALLEST complete thing that runs and produces "
        "visible output. Show the command AND its real output.\n"
        "  f. USAGE — the handful of things people actually do, with examples.\n"
        "  g. CONFIGURATION — real env var and flag names, defaults, where the "
        "config file lives.\n"
        "  h. HOW IT WORKS — a short architecture pass, so a reader can predict "
        "behavior rather than memorize commands.\n"
        "  i. TROUBLESHOOTING — the failures a new user will actually hit first.\n"
        "  j. POINTERS — contributing, license, where to ask for help.\n"
        "Skip a section only when it genuinely does not apply, and know which one "
        "you skipped. Sections a, d, and e are never optional: a reader who cannot "
        "tell what it is, install it, or run it once has gotten nothing.\n"
    )

ctx += "</system-reminder>"

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
