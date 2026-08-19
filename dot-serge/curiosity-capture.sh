#!/usr/bin/env bash
# Serge curiosity capture — Stop hook, $0, no LLM, capture only.
#
# WHY (user, 2026-08-16): "can we also have serge learn skills on his own as he
# comes across them? like very curious about things if he doesn't know."
#
# skill-learn.sh already journals learning moments, but it is a UserPromptSubmit
# hook, so BOTH its signals come out of the user's mouth: a CORRECTION ("no, you
# got that wrong") and a GAP ("do X", where no skill covers X). Nothing captures
# the far more common event — Serge itself hitting something it did not know and
# going to find out. Measured on the live journal: 187 entries, every one
# `gap_candidate`, zero corrections. Skill evolution was learning only from what
# it was TOLD, never from what it DID.
#
# This closes that. It watches the turn Serge just finished and journals two
# self-observed signals:
#
#   LOOKED-UP  — a WebSearch / WebFetch happened. Serge did not know something
#                and went and read about it. That is the literal definition of
#                the curiosity the user asked for, and it is already free to
#                observe: the search query IS the topic.
#   HARD-WAY   — the same tool failed repeatedly against the same target and
#                then succeeded. That is a lesson bought with real turns, and
#                skill-evolve already has a "## Learned the hard way" section in
#                every SKILL.md waiting for exactly it.
#
# Capture only, same doctrine as skill-learn.sh: never blocks, never edits a
# skill, never calls a model. skill-evolve.mjs (nightly loop) does the judging,
# behind its own safety gate that reverts any edit whose skill tests fail.
#
# NOISE DISCIPLINE. The existing gap_candidate channel already proves the failure
# mode: it captured 187 raw prompts, most of them eval tasks, which is input that
# makes distillation worse rather than better. So this hook is deliberately
# stingy — at most MAX_PER_TURN entries, deduped, searches only (not every tool
# call), and nothing at all on a turn that did no looking up.
#
# Off-switch: SERGE_CURIOSITY_DISABLE=1
set -uo pipefail

[ "${SERGE_CURIOSITY_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}" python3 - "$input" <<'PY'
import json, os, re, sys, time
from pathlib import Path

MAX_PER_TURN = 3

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

tx = d.get("transcript_path") or ""
if not tx or not os.path.exists(tx):
    sys.exit(0)

home = Path(os.environ["SERGE_HOME"])
journal = home / "skills" / "_learnings" / "journal.jsonl"

# ── walk the turn since the last real user message ───────────────────────────
user_text = ""
searches: list[str] = []          # WebSearch queries / WebFetch urls
attempts: dict[str, list[bool]] = {}   # "tool\0target" -> [ok, ok, ...]
pending: dict[str, str] = {}      # tool_use_id -> key

def target_of(name: str, inp: dict) -> str:
    for k in ("file_path", "url", "path", "pattern", "command"):
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:120]
    return name

try:
    with open(tx, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"user"' not in line and '"assistant"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            msg = e.get("message") or {}
            if e.get("type") == "user":
                c = msg.get("content")
                if isinstance(c, str):
                    t = c
                elif isinstance(c, list):
                    t = "\n".join(b.get("text", "") for b in c
                                  if isinstance(b, dict) and b.get("type") == "text")
                else:
                    t = ""
                if t.strip() and not e.get("isMeta"):
                    # a new human turn resets everything we were accumulating
                    user_text, searches, attempts, pending = t.strip(), [], {}, {}
                    continue
                for b in (c if isinstance(c, list) else []):
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        key = pending.pop(b.get("tool_use_id"), None)
                        if key:
                            attempts.setdefault(key, []).append(not b.get("is_error"))
                continue
            for b in (msg.get("content") or []):
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                name, inp = b.get("name") or "", b.get("input") or {}
                if name == "WebSearch":
                    q = str(inp.get("query") or "").strip()
                    if q:
                        searches.append(q)
                elif name == "WebFetch":
                    u = str(inp.get("url") or "").strip()
                    if u:
                        searches.append(u)
                tid = b.get("id")
                if tid:
                    pending[tid] = f"{name}\0{target_of(name, inp)}"
except Exception:
    sys.exit(0)

if not user_text:
    sys.exit(0)

entries = []

# LOOKED-UP: dedupe, keep order, cap.
seen = set()
looked = []
for s in searches:
    k = s.lower()
    if k in seen:
        continue
    seen.add(k)
    looked.append(s)
if looked:
    entries.append({
        "kind": "self_learned",
        "text": ("While working on: " + " ".join(user_text.split())[:200]
                 + " — Serge did not know this and looked it up: "
                 + "; ".join(looked[:4])[:600]
                 + ". If this is durable knowledge, it belongs in a skill."),
    })

# HARD-WAY: failed repeatedly on one target, then succeeded.
for key, results in attempts.items():
    if len(results) < 3 or not results[-1]:
        continue
    fails = results.count(False)
    if fails < 2:
        continue
    tool, target = key.split("\0", 1)
    entries.append({
        "kind": "self_learned",
        "text": (f"Solved the hard way while working on: "
                 + " ".join(user_text.split())[:160]
                 + f" — {tool} on `{target}` failed {fails}x before succeeding. "
                 "The working approach is worth recording so the next attempt is the first one."),
    })

if not entries:
    sys.exit(0)

# Journal each turn ONCE. Stop hooks re-fire when a gate blocks and the turn
# continues, so without this the same searches get captured on every nudge cycle
# — and a journal full of duplicates is exactly the input that makes distillation
# worse, which the gap_candidate channel already demonstrated.
import hashlib
sig = hashlib.sha1(
    ("|".join(e["text"] for e in entries)).encode("utf-8", "ignore")
).hexdigest()[:16]
mark = Path(os.environ.get("TMPDIR", "/tmp")) / f"serge-curiosity-{sig}"
if mark.exists():
    sys.exit(0)
try:
    mark.touch()
except Exception:
    pass

try:
    journal.parent.mkdir(parents=True, exist_ok=True)
    with open(journal, "a", encoding="utf-8") as fh:
        for e in entries[:MAX_PER_TURN]:
            e["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            fh.write(json.dumps(e) + "\n")
except Exception:
    pass
PY
