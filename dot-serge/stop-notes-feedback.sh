#!/usr/bin/env bash
# Serge UserPromptSubmit hook — closes the Gather→Act→Verify loop.
#
# THE GAP THIS FILLS
# Serge's verify stage is strong but its output was write-only from the model's
# point of view. verify-on-stop.sh and review-on-stop.sh compute real findings
# every turn, then hand them to the harness as `systemMessage` — and
# utils/messages.ts serializes that attachment as `return []`, i.e. it renders
# for the human and NEVER enters model context. With SERGE_REVIEW_ENFORCE
# defaulting to 0, the reviewer's findings were computed, displayed, discarded.
# Serge paid for a review it could not learn from.
#
# Only the BLOCKING path (exit 2 → stderr) ever reached the model, and that
# fires solely on hard failures. Soft findings — the "you should probably…"
# class that is most of a reviewer's value — evaporated.
#
# HOW THIS CLOSES IT
# stop-checks.sh now files those findings to $NOTES. This hook feeds the newest
# block into the NEXT turn as additionalContext, then consumes it so it is never
# repeated. Verify output becomes Gather input — evidence for the next decision,
# which is the whole point of the loop.
#
# COST: zero extra model calls (the notes already exist), and zero tokens on
# turns with no findings. Capped at $MAX chars so a pathological review cannot
# blow up the context budget.
#
# NOT a duplicate of reflexion-load.sh: that injects REPEATED failures once per
# session (coarse, historical). This injects THIS turn's findings on the next
# turn (fine-grained, current). They compose.
#
# Disable with SERGE_STOP_NOTES_FEEDBACK=0.
set -uo pipefail

cat >/dev/null   # drain the hook JSON on stdin; we don't need it

[ "${SERGE_STOP_NOTES_FEEDBACK:-1}" = "0" ] && exit 0

SH="${SERGE_HOME:-$HOME/.serge}"
NOTES="${SERGE_STOP_NOTES_FILE:-$SH/last-stop-notes.md}"
MAX="${SERGE_STOP_NOTES_MAX:-1500}"

[ -s "$NOTES" ] || exit 0

python3 - "$NOTES" "$MAX" <<'PY'
import json, os, sys

path, maxlen = sys.argv[1], int(sys.argv[2])
try:
    raw = open(path).read().strip()
except Exception:
    sys.exit(0)
if not raw:
    sys.exit(0)

# Keep only the most recent "## <timestamp>" block — older ones are stale by
# definition (the diff has moved on) and would just cost tokens.
blocks = raw.split("\n## ")
body = ("## " + blocks[-1]).strip() if len(blocks) > 1 else raw
# Strip the timestamp heading itself; the content is what matters.
lines = [l for l in body.splitlines() if not l.startswith("## ")]
body = "\n".join(lines).strip()
if not body:
    open(path, "w").close()
    sys.exit(0)

truncated = False
if len(body) > maxlen:
    body = body[:maxlen]
    truncated = True

ctx = (
    "Findings from the automated verify/review pass on your PREVIOUS turn "
    "(deterministic checks + diff review). These are evidence about work you "
    "already did, not new instructions from the user — weigh them, and if a "
    "finding is wrong say why rather than silently complying:\n\n"
    + body
    + ("\n[…truncated]" if truncated else "")
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": ctx,
    }
}))

# Consume: findings are delivered exactly once. Archive rather than delete so
# the history is still inspectable.
try:
    with open(os.path.join(os.path.dirname(path), "stop-notes-archive.md"), "a") as a:
        a.write("\n" + body + "\n")
except Exception:
    pass
open(path, "w").close()
PY
exit 0
