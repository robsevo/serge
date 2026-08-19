#!/usr/bin/env bash
# Serge discovery delegation nudge — UserPromptSubmit hook ($0, no LLM).
#
# WHY: `~/.serge/agents/scout.md` has existed for weeks and fires almost never.
# In the measured session (f85b9672, 2026-07-29) the opening prompt was "Verify
# the entire codebase, make sure everything is there" — the exact shape scout was
# built for. Instead Serge serially Read 25 whole files into its own context, and
# then STILL invented a path it had already read. A capability the model never
# reaches for is not integrated, it is just present.
#
# HONEST LIMITATION, stated up front: this one is a NUDGE, not a gate. Unlike
# path-reality-gate.sh (which denies) and repo-card.sh / reference-resolve.sh
# (which supply facts), this only puts the option in front of the model at the
# moment it applies. A weak seat can ignore it — that is exactly what happened to
# CONSTITUTION.md:167, which already says to offload discovery to a
# scout. Expect partial efficacy; the honest test is whether scout spawn counts
# rise on broad-discovery turns.
#
# Fires only when BOTH hold, so it stays quiet on ordinary turns:
#   1. the prompt is a broad discovery / comprehension ask, and
#   2. the workspace is actually big enough for delegation to pay for itself
#      (>250 files or >8 top-level dirs) — in a 10-file repo, reading directly
#      is correct and a subagent is pure overhead.
#
# Safety: off-switch SERGE_DISCOVERY_DELEGATE_DISABLE=1; ignores harness plumbing
# (task notifications / system reminders) per tests/test-hook-wrappers.sh; bounded
# 1s count walk; fails open silently.
set -uo pipefail

[ "${SERGE_DISCOVERY_DELEGATE_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the model, not the harness: nudging a golden task toward a scout
# changes its strategy and its token profile against a baseline that had neither.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re, time

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"
prompt = re.sub(_WRAPPERS, " ", str(d.get("prompt") or ""), flags=re.S).strip()
if not prompt or len(prompt) > 6000:
    sys.exit(0)

# Broad discovery asks. Deliberately excludes narrow, already-located requests
# ("fix line 40 of app.py") — those need no scout.
BROAD = re.compile(
    r"\b("
    r"verify (?:the )?(?:entire|whole|complete)?\s*(?:codebase|repo|project|code)"
    r"|(?:is|make sure) everything (?:is )?(?:there|working|accounted)"
    r"|accounted for"
    r"|how does (?:this|the|it) \w+ work"
    r"|explain (?:the )?(?:architecture|codebase|structure|design|flow)"
    r"|walk me through (?:the )?(?:code|codebase|architecture|repo)"
    r"|where (?:is|are|does|do)\b.{0,40}\b(?:defined|implemented|handled|live|called|used)"
    r"|find (?:all|every)\b"
    r"|trace (?:the|how|through)\b"
    r"|map (?:out )?(?:the )?(?:codebase|repo|architecture|dependencies)"
    r"|audit (?:the )?(?:entire|whole|codebase|repo|project)"
    r"|what calls\b|which files\b|understand (?:the|this) (?:codebase|repo|project)"
    r")\b",
    re.IGNORECASE,
)
if not BROAD.search(prompt):
    sys.exit(0)

root = os.path.abspath(os.path.expanduser(str(d.get("cwd") or ".")))
if not os.path.isdir(root):
    sys.exit(0)

SKIP = {
    ".git", "node_modules", "dist", "build", "out", ".venv", "venv",
    "__pycache__", ".next", ".nuxt", ".cache", "target", "vendor", ".turbo",
    ".mypy_cache", ".pytest_cache", ".tox", ".ruff_cache", "coverage",
    "site-packages", ".terraform", ".gradle", ".idea", ".svelte-kit",
}

files = 0
topdirs = 0
deadline = time.time() + 1.0
try:
    topdirs = len(
        [
            e
            for e in os.listdir(root)
            if os.path.isdir(os.path.join(root, e))
            and e not in SKIP
            and not e.startswith(".")
        ]
    )
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [x for x in dirnames if x not in SKIP]
        files += len(filenames)
        if files > 250 or time.time() > deadline:
            break
except Exception:
    sys.exit(0)

# Small repo → reading directly IS the right call. Stay quiet.
if files <= 250 and topdirs <= 8:
    sys.exit(0)

ctx = (
    "<system-reminder>\n"
    "This is a broad discovery ask in a large workspace (%d+ files, %d top-level dirs). "
    "You have a scout subagent built for exactly this: Agent tool, subagent_type "
    "\"scout\" — read-only, runs on the cheap burst seat, returns the conclusion plus "
    "file:line refs instead of dumping file contents into your context.\n\n"
    "Prefer it over reading many whole files yourself. Measured cost of not doing so "
    "(2026-07-29): 25 serial whole-file Reads for one 'verify the codebase' turn, after "
    "which a path that had already been read was still written wrong — a full context is "
    "how file paths get lost.\n\n"
    "Use it well: one scout per independent question (not one per file), name the exact "
    "question and where to start, and require file:line refs in the answer so you can "
    "verify without re-reading. Keep the conclusion, discard the search. Do the "
    "reasoning, editing and verifying yourself — scout locates, it does not decide. If "
    "the question is narrow enough that you already know the file, just read it.\n"
    "</system-reminder>" % (files, topdirs)
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
exit 0
