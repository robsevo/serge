#!/usr/bin/env bash
# Serge UserPromptSubmit hook — surface the screenshot capability, ON REQUEST ONLY.
#
# User decision 2026-07-27: "build it, only when i ask for eyes." So this does
# NOT fire when text extraction looks thin, and does NOT nudge serge toward
# screenshots on its own. It fires only when the user explicitly asks to SEE a
# page, and then tells serge the tool exists and how to use it.
#
# Why a hook at all rather than just shipping the script: a capability serge
# doesn't know about is a capability that never gets used. There is no tool
# registration for shell scripts, so the only way "give me eyes on this page"
# works is if something puts webshot.sh in front of the model at that moment.
#
# Cost: zero tokens on every turn that doesn't ask for eyes.
# Off-switch: SERGE_EYES_DIRECTIVE_DISABLE=1
set -uo pipefail

[ "${SERGE_EYES_DIRECTIVE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, re

_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

prompt = re.sub(_WRAPPERS, " ", str(d.get("prompt") or ""), flags=re.S).strip()
if not prompt:
    sys.exit(0)

# An explicit request to SEE something rendered. Deliberately narrow — this is
# opt-in by user instruction, so a miss (user rephrases) is much cheaper than a
# false fire (a screenshot nobody wanted, at thousands of tokens).
VISUAL = re.compile(
    r"\b("
    r"eyes on|take a look at (?:the )?(?:page|site|url)|screenshot|screen shot"
    r"|what does (?:it|the (?:page|site)) look like"
    r"|(?:view|render|see|show me) (?:the )?(?:page|site|url|screen)"
    r"|visually (?:check|inspect|verify)|how does it (?:look|render)"
    r")\b",
    re.IGNORECASE,
)
if not VISUAL.search(prompt):
    sys.exit(0)

ctx = (
    "<system-reminder>\n"
    "The user asked to SEE a page rendered. You have a screenshot tool:\n\n"
    "  ~/.serge/webshot.sh <url> [out.png]        # prints the PNG path\n"
    "  WEBSHOT_INSECURE=1 ...                     # self-signed/local hosts\n"
    "  WEBSHOT_HEIGHT=4000 ...                    # taller capture, long pages\n\n"
    "Run it with Bash, then Read the PNG it prints — Read returns the image and "
    "you will actually see the page.\n\n"
    "Rules:\n"
    "- Exit code 3 means the capture is an ERROR PAGE (cert, DNS, HTTP error), "
    "NOT the site. Never describe that image as the page's content; report the "
    "failure and what it says.\n"
    "- A screenshot costs far more tokens than WebFetch, which already "
    "summarizes a page to a few hundred characters. Use eyes because the user "
    "asked, not as a default.\n"
    "- The image goes to whichever provider serves the current seat. Gemini "
    "seats accept images; mistral-large does not. Do not screenshot anything "
    "behind a login.\n"
    "</system-reminder>"
)
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))
PY
exit 0
