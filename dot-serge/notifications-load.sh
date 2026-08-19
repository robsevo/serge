#!/usr/bin/env bash
# SessionStart hook — surface pending loop notifications (~/.serge/NOTIFICATIONS.md).
#
# The autonomous loops (eval-gate, err-triage, backlog — see loops/README.md)
# append "- [ ] <date> <summary>" lines when something needs a human. This
# loader injects the unchecked lines at session start with an instruction to
# surface them; the agent/human checks items off ("- [x]") after handling —
# no auto-rotation, so nothing is lost to a compact.
#
# 2026-07-29: the injection is now BOUNDED. It was unbounded, and by then the file
# held 49 pending items going back 16 days — 6.8 KB (~1.7k tokens) prepended to
# EVERY session, growing forever, mostly notices from two weeks ago. Now the newest
# SERGE_NOTIF_MAX (default 10) are injected and the rest are named as a count with
# the file path, so an unattended backlog costs a line instead of a page. Nothing is
# deleted — the file remains the record.
#
# Guards: skipped inside eval children and inside loop runs themselves.
set -uo pipefail
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
[ "${SERGE_LOOP_ACTIVE:-0}" = "1" ] && exit 0

N="${SERGE_HOME:-$HOME/.serge}/NOTIFICATIONS.md"
[ -s "$N" ] || exit 0

python3 - "$N" "${SERGE_NOTIF_MAX:-10}" <<'PY'
import json, sys, os, re

path = sys.argv[1]
try:
    cap = max(1, int(sys.argv[2]))
except (ValueError, IndexError):
    cap = 10

pending = [ln.rstrip() for ln in open(path) if ln.lstrip().startswith("- [ ]")]
if not pending:
    sys.exit(0)

# Newest first by the ISO date each loop stamps into the line; undated lines sort
# last but are never dropped from the count.
def key(ln):
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", ln)
    return m.group(1) if m else ""

shown = sorted(pending, key=key, reverse=True)[:cap]
hidden = len(pending) - len(shown)

ctx = ("[serge-loops] Pending notifications from the autonomous loops "
       "(briefly surface these to the user at the start of the session; "
       "after they are acknowledged/handled, flip the checkbox to '- [x]' "
       f"in {path}):\n" + "\n".join(shown))
if hidden > 0:
    ctx += (f"\n… and {hidden} older pending item(s) not shown — read {path} if "
            "the user asks, or to work the backlog down.")
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx}}))
PY
exit 0
