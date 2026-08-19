#!/usr/bin/env bash
# Serge reflexion logger — records an EXTERNAL-ground-truth failure (typecheck /
# lint / test / completion caught by verify-on-stop) as a structured JSONL entry.
# This is the Reflexion-with-external-feedback pattern: the signal is real tool
# output, NOT the model judging itself (which the research shows is unreliable).
# SessionStart (reflexion-load.sh) and the reflection loop consult these so Serge
# learns from RECURRING mistakes instead of repeating them.
#
# Called by verify-on-stop.sh on any real failure, in enforce OR nudge mode.
#   stdin : the failure text (FAILURES + SOFT_FAILURES)
#   $1    : cwd        $2 : enforce(0|1)        $3 : changed files (newline-sep)
# Appends one JSON object per line to ~/.serge/reflexion-log.jsonl. Fail-open,
# recursion-guarded, capped. jq isn't installed here → python3 does the JSON.
set -uo pipefail
[ "${SERGE_REFLEXION_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_REFLEXION_ACTIVE:-0}" = "1" ] && exit 0   # re-entry guard
command -v python3 >/dev/null 2>&1 || exit 0

LOG="${SERGE_REFLEXION_LOG:-$HOME/.serge/reflexion-log.jsonl}"
CAP="${SERGE_REFLEXION_CAP:-500}"
fail_text="$(cat)"
case "$fail_text" in *[!$' \t\n']*) : ;; *) exit 0 ;; esac   # nothing real to log

SERGE_REFLEXION_ACTIVE=1 LOG="$LOG" CAP="$CAP" CWD="${1:-}" ENFORCE="${2:-0}" FILES="${3:-}" \
python3 - "$fail_text" <<'PY' 2>/dev/null || true
import os, sys, json, re, hashlib, datetime

text = sys.argv[1] if len(sys.argv) > 1 else ""
log = os.environ["LOG"]
cap = int(os.environ.get("CAP", "500") or "500")

# Failing check labels = the "### <label>" headers verify-on-stop writes.
cats = []
for m in re.findall(r'^###\s*(.+)$', text, re.M):
    lbl = m.split('(')[0].strip()
    if lbl and lbl not in cats:
        cats.append(lbl)

# Error codes (TS2345, ruff F841/E501, etc.) — stable recurrence keys across paths.
codes = sorted(set(re.findall(r'\b(?:TS\d{3,5}|[EWFCNB]\d{2,4})\b', text)))

files = [f.strip() for f in os.environ.get("FILES", "").splitlines() if f.strip()][:12]

# Signature = WHAT failed (labels) + WHICH codes — independent of line numbers/paths,
# so the same mistake recurring is detectable across turns.
sig_src = "|".join(sorted(cats)) + "::" + "|".join(codes)
sig = hashlib.sha1(sig_src.encode()).hexdigest()[:12]

# Recurrence: count prior entries sharing this signature; load existing lines.
prior, entries = 0, []
try:
    with open(log, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            entries.append(line)
            try:
                if json.loads(line).get("sig") == sig:
                    prior += 1
            except Exception:
                pass
except FileNotFoundError:
    pass

entry = {
    "ts": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "sig": sig,
    "count": prior + 1,          # this occurrence's ordinal for this signature
    "categories": cats[:8],
    "codes": codes[:12],
    "files": files,
    "enforce": os.environ.get("ENFORCE", "0"),
    "cwd": os.environ.get("CWD", ""),
}
entries.append(json.dumps(entry, ensure_ascii=False))
if len(entries) > cap:           # keep the most recent `cap` lines
    entries = entries[-cap:]
tmp = log + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write("\n".join(entries) + "\n")
os.replace(tmp, log)
PY
exit 0
