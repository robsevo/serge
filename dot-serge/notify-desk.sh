#!/usr/bin/env bash
# Serge desktop notifier — Notification event ($0, no LLM, side effects only).
#
# WHY: serge stops and waits — for a permission decision, or because a long turn
# finished — and if the terminal isn't focused nobody knows. The waiting is
# invisible, so the cost is however long it takes you to look.
#
# CONTRACT (verified in this fork, and it differs from the public docs):
#   - Notification carries message, title?, notification_type
#     (coreTypes.generated.ts:362).
#   - The docs say a Notification hook can return {"terminalSequence": ...} to
#     raise a desktop/terminal alert. `terminalSequence` appears NOWHERE in this
#     fork's src/ — it is not implemented here. So this hook does the alerting
#     itself via notify-send rather than returning a field that gets discarded.
#   - Notification is not among the seven events that accept additionalContext
#     (hooks.ts:805-845), so nothing is injected into the conversation and this
#     costs zero tokens, always.
#
# Safety: off-switch SERGE_NOTIFY_DESK_DISABLE=1 · no-op when notify-send is
# absent or no display is attached (SSH/headless) · never prints to stdout or
# stderr, so it cannot inject text or spam the transcript · truncates the body.
set -uo pipefail

[ "${SERGE_NOTIFY_DESK_DISABLE:-0}" = "1" ] && exit 0
command -v notify-send >/dev/null 2>&1 || exit 0
# Headless / no session bus → nothing to notify.
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

payload="$(python3 - "$input" <<'PY' 2>/dev/null
import sys, json

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "Notification":
    sys.exit(0)

ntype = str(d.get("notification_type") or "")
msg = " ".join(str(d.get("message") or "").split())[:180]
if not msg:
    sys.exit(0)

# Urgency by kind: a permission prompt blocks all progress until answered.
URGENT = {"permission_prompt", "agent_needs_input", "elicitation_dialog"}
urgency = "critical" if ntype in URGENT else "normal"
title = str(d.get("title") or "").strip() or {
    "permission_prompt": "Serge needs permission",
    "agent_needs_input": "Serge needs input",
    "idle_prompt": "Serge is waiting",
    "agent_completed": "Serge finished",
}.get(ntype, "Serge")

print(json.dumps({"u": urgency, "t": title, "m": msg}))
PY
)"

[ -n "$payload" ] || exit 0

u="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["u"])' 2>/dev/null)"
t="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["t"])' 2>/dev/null)"
m="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["m"])' 2>/dev/null)"
[ -n "$m" ] || exit 0

notify-send -a "serge" -u "${u:-normal}" "${t:-Serge}" "$m" >/dev/null 2>&1 || true
exit 0
