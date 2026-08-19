#!/usr/bin/env bash
# Serge plan pointer — SessionStart hook (startup | resume | compact).
#
# Companion to persist-plan.sh. When a repo has a plan.md (written by the
# plan-mode persistence hook), this injects a ~20-token POINTER — not the plan
# itself — so the executor seat reads the plan straight from source when it
# starts implementing. "Plan high, execute cheap": the cheap seat gets nudged to
# the durable plan without us paying to carry the full plan in every session's
# context (which would also go stale). The model Reads plan.md on demand, so the
# full plan enters context exactly when needed and not a turn sooner.
#
# PRICING: the injected pointer is ~20 tokens and ONLY rides along when a plan.md
# actually exists. No plan.md -> zero output -> zero cost. The hook itself is a
# local file stat, not an LLM.
#
# jq is NOT installed on this host — JSON via python3, like Serge's other hooks.
# Safe no-op when: no python3, no plan.md, or disabled. Must exit 0 and write
# ONLY to stdout so the harness can inject the additionalContext.
set -uo pipefail

[ "${SERGE_PLAN_POINTER_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

# Resolve the project root the SAME way persist-plan.sh does, so the pointer looks
# exactly where the plan was written: CLAUDE_PROJECT_DIR, else cwd from the
# SessionStart JSON, else the hook's own working dir.
project="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$project" ]; then
  project="$(printf '%s' "$input" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
print(d.get("cwd") or "")
' 2>/dev/null)"
fi
[ -z "$project" ] && project="$PWD"

PLAN_FILE="${SERGE_PLAN_FILE:-plan.md}"
PLAN_PATH="$project/$PLAN_FILE"
[ -f "$PLAN_PATH" ] || exit 0      # no plan -> nothing to point at

# Emit the pointer (+ a freshness hint so a stale plan is visible) as SessionStart
# additionalContext. python3 does the JSON and the mtime.
python3 - "$PLAN_PATH" "$PLAN_FILE" <<'PY'
import json, sys, os, datetime
path, rel = sys.argv[1], sys.argv[2]
try:
    mtime = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone().strftime("%Y-%m-%d %H:%M")
except Exception:
    mtime = "unknown"
ctx = (
    f"A saved plan exists at `{rel}` (last updated {mtime}). Read it from source "
    f"before implementing, and follow it. If the work has moved beyond this plan "
    f"or it looks stale, say so rather than following it blindly."
)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
exit 0
