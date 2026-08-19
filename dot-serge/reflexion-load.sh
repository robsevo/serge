#!/usr/bin/env bash
# Serge reflexion loader — SessionStart hook. Surfaces RECURRING verify failures
# (external ground truth from ~/.serge/reflexion-log.jsonl) so Serge consults past
# mistakes before working — the SelfCorrectionEngine `check_against_past_mistakes`
# pattern, wired to real tool output instead of self-judgment. "Recurring" = a
# failure signature seen >= SERGE_REFLEXION_MIN_RECUR times. No model call,
# ~milliseconds. Emits hookSpecificOutput.additionalContext (same contract as
# memory-load.sh). Safe no-op when: no python3, no log, or nothing recurring.
set -uo pipefail
command -v python3 >/dev/null 2>&1 || exit 0
LOG="${SERGE_REFLEXION_LOG:-$HOME/.serge/reflexion-log.jsonl}"
[ -f "$LOG" ] || exit 0
MIN="${SERGE_REFLEXION_MIN_RECUR:-2}"   # min occurrences to count as "recurring"
TOP="${SERGE_REFLEXION_TOP:-5}"          # show at most N recurring patterns

LOG="$LOG" MIN="$MIN" TOP="$TOP" python3 - <<'PY' 2>/dev/null || exit 0
import os, json
log = os.environ["LOG"]; MIN = int(os.environ["MIN"]); TOP = int(os.environ["TOP"])

by = {}
try:
    for line in open(log, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        sig = e.get("sig")
        if not sig:
            continue
        cnt = e.get("count", 1)
        cur = by.get(sig)
        # keep the entry carrying the highest occurrence count for this signature
        if cur is None or cnt >= cur["count"]:
            by[sig] = {"count": cnt, "e": e}
except FileNotFoundError:
    raise SystemExit(0)

recur = [v for v in by.values() if v["count"] >= MIN]
recur.sort(key=lambda v: (v["count"], v["e"].get("ts", "")), reverse=True)
recur = recur[:TOP]
if not recur:
    raise SystemExit(0)

lines = []
for v in recur:
    e = v["e"]
    cats = ", ".join(e.get("categories") or []) or "verify failure"
    codes = " ".join(e.get("codes") or [])
    files = ", ".join((e.get("files") or [])[:3])
    desc = cats + (f" [{codes}]" if codes else "")
    where = f" in {files}" if files else ""
    lines.append(f"  • {desc}{where} — seen {v['count']}× (last {e.get('ts','')[:10]})")

ctx = ("Serge reflexion memory — these verify checks have FAILED REPEATEDLY in past "
       "turns (external ground truth, not self-judgment). Before editing related "
       "code, account for them so you don't repeat the mistake:\n" + "\n".join(lines) +
       "\n(Full log: ~/.serge/reflexion-log.jsonl)")
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
exit 0
