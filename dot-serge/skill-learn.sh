#!/usr/bin/env bash
# Serge skill-learning CAPTURE hook ($0, no LLM) — the cheap half of skill self-improvement.
#
# WHY: Serge's skills should get better every time something is learned the hard way. Distilling
# that needs judgment (an LLM), but DETECTING it must be free and instant — so this hook only
# spots a learning moment and journals it with context. `skill-evolve.mjs` (nightly loop, or run
# by hand) does the reasoning: edit the matching SKILL.md, or propose a NEW skill when a gap has
# no owner. Cheap capture + gated distillation is the same split the eval/gate loops already use.
#
# Captures two signals:
#   1. CORRECTION — the user says Serge got it wrong / told it not to do something. The most
#      valuable training signal there is, and it is otherwise lost when the session ends.
#   2. GAP — the user asks for a domain no current skill covers (candidate for a NEW skill).
#
# Writes JSONL to ~/.serge/skills/_learnings/journal.jsonl. Never blocks, never edits anything,
# never speaks to the model — capture only. Off-switch: SERGE_SKILL_LEARN_DISABLE=1
set -uo pipefail

[ "${SERGE_SKILL_LEARN_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"
SERGE_HOME="${SERGE_HOME:-$HOME/.serge}" python3 - "$input" <<'PY'
import json, os, re, sys, time
from pathlib import Path

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
clean = re.sub(_WRAPPERS, " ", prompt, flags=re.S).strip()
if not clean or clean.startswith("/") or len(clean) > 6000:
    sys.exit(0)

home = Path(os.environ.get("SERGE_HOME", os.path.expanduser("~/.serge")))
skills_dir = home / "skills"
# Future skills are picked up automatically — this reads the directory, never a hardcoded list.
known = sorted(p.name for p in skills_dir.glob("*") if (p / "SKILL.md").exists()) if skills_dir.exists() else []

CORRECTION = re.compile(
    r"(?:^|\b)(?:no[,.]? (?:that'?s|it'?s|you)|that'?s (?:wrong|incorrect|not right|not what)|"
    r"you (?:were|are) wrong|don'?t (?:do|use|ever)|stop (?:doing|using)|"
    r"never (?:do|use)|actually,? (?:it|you|the)|not like that|wrong (?:approach|way)|"
    r"you (?:keep|always) (?:doing|getting)|i (?:told|said) you)", re.I)

# A gap: an explicit build/help request whose vocabulary matches no installed skill name.
GAP = re.compile(r"\b(?:build|create|make|write|set ?up|implement|help me with|how do i)\b", re.I)

entry = None
if CORRECTION.search(clean):
    entry = {"kind": "correction", "text": clean[:1200]}
elif GAP.search(clean):
    words = set(re.findall(r"[a-z]{4,}", clean.lower()))
    # crude but free: if no known skill name appears in the ask, it MAY be an uncovered domain
    if known and not any(k.lower() in clean.lower() for k in known) and len(words) > 3:
        entry = {"kind": "gap_candidate", "text": clean[:600]}

if not entry:
    sys.exit(0)

entry.update({
    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "cwd": str(d.get("cwd") or ""),
    "session": str(d.get("session_id") or "")[:12],
    "known_skills": known,
})
out = skills_dir / "_learnings"
try:
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "journal.jsonl", "a") as f:
        f.write(json.dumps(entry) + "\n")
except Exception:
    pass  # capture must never break a turn
PY
exit 0
