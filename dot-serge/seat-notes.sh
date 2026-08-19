#!/usr/bin/env bash
# Serge seat notes — SubagentStart (inject) + SubagentStop (harvest) ($0, no LLM).
#
# WHY: serge's org graph promises long-lived seats that "own a zone and accumulate context
# over time" — but nothing accumulates. `agents/*.md` are static role definitions, and every
# spawn of `scout` or `backend` starts cold: it re-derives the same zone facts, pays for the
# same searches, and re-learns the same gotcha the previous scout hit an hour ago. The seat
# is long-lived in name only.
#
# Three hooks already feed a subagent at spawn, and each covers a different blindness:
#   repo-card.sh           → what this repo LOOKS LIKE (structure)
#   subagent-brief-gate.sh → what this repo FORBIDS (constraints) + serge's memory (lessons)
#   this                   → what THIS SEAT learned in THIS project last time (experience)
#
# THE LOOP (deterministic, no model call on either side):
#   SubagentStart — inject this seat's accumulated notes for this project (recall).
#   [the ASK]     — lives in subagent-brief-gate.sh, appended to the BRIEF via `updatedInput`,
#                   NOT here. Measured: a SubagentStart reminder arrives (a seeded codeword
#                   came back in a live subagent's answer) but does not survive to the report
#                   written many tool calls later — three live runs harvested nothing. Moving
#                   the ask into the brief produced a ZONE NOTE on the next run.
#   SubagentStop  — harvest `ZONE NOTE:` lines from the final report, dedupe, cap, store.
#
# Notes are per (project, seat) so a `backend` note from example-web never leaks into example-api,
# and a `scout` note never lands in `security`'s context.
#
# DELIBERATELY NOT MEMORY. `~/.serge/memory` is serge's curated, cross-project, human-
# reviewed store with its own write rules. This is a scratch lane: cheap, local, capped,
# self-pruning (FIFO), and safe to delete at any time — `rm -rf ~/.serge/seat-notes`
# costs nothing but a few re-derivations. If a note turns out to be systemic, it belongs in
# memory, written the normal way.
#
# Safety:
#   1. Off-switch: SERGE_SEAT_NOTES_DISABLE=1
#   2. Fails open on any error — a missing or corrupt note file never blocks a spawn.
#   3. Caps: SEAT_MAX notes/seat (FIFO), NOTE_MAX chars each. Bounded forever.
#   4. Never blocks, never denies, writes nothing outside ~/.serge/seat-notes/.
#
# Wired in ~/.serge/settings.json as SubagentStart "*" and SubagentStop "*".
set -uo pipefail

[ "${SERGE_SEAT_NOTES_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re

SEAT_MAX = int(os.environ.get("SERGE_SEAT_NOTES_MAX", "12"))
NOTE_MAX = 240
ROOT = os.path.expanduser("~/.serge/seat-notes")

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

# Diagnostic log (opt-in): SERGE_SEAT_NOTES_LOG=/path/to.jsonl
# Same reason the brief gate has one: when the loop produces nothing, you must be able to
# tell "the hook never ran" from "it ran and decided not to act" without guessing.
def _log(**kw):
    p = os.environ.get("SERGE_SEAT_NOTES_LOG") or ""
    if not p:
        return
    try:
        with open(p, "a") as fh:
            fh.write(json.dumps(kw) + "\n")
    except Exception:
        pass

event = str(d.get("hook_event_name") or "")
_msg = str(d.get("last_assistant_message") or "")
_log(event=event, seat=str(d.get("agent_type") or ""),
     msglen=len(_msg), had_note=("ZONE NOTE" in _msg.upper()))
if event not in ("SubagentStart", "SubagentStop"):
    sys.exit(0)

seat = str(d.get("agent_type") or "").strip().lower()
seat = re.sub(r"[^a-z0-9_-]+", "-", seat).strip("-")
if not seat:
    sys.exit(0)  # can't attribute a note to a seat we can't name

cwd = os.path.abspath(os.path.expanduser(str(d.get("cwd") or os.getcwd())))
slug = re.sub(r"[^A-Za-z0-9]+", "-", cwd).strip("-").lower()[:120] or "no-project"
path = os.path.join(ROOT, slug, seat + ".md")


def read_notes():
    try:
        with open(path, "r", errors="ignore") as fh:
            return [ln.rstrip() for ln in fh if ln.strip().startswith("- ")]
    except Exception:
        return []


# --- SubagentStart: hand the seat its own past ------------------------------
if event == "SubagentStart":
    notes = read_notes()

    # INJECTION ONLY. The *ask* for a ZONE NOTE does NOT live here — it is appended to the
    # BRIEF by subagent-brief-gate.sh (PreToolUse `updatedInput`).
    #
    # Why: this is the reminder-vs-artifact split, measured twice now. A SubagentStart
    # reminder demonstrably ARRIVES — a probe seeded a codeword that exists in no file the
    # subagent can read, and the subagent recited it — but arriving is not the same as
    # shaping the report written many tool calls later. Three live runs with the ask in this
    # reminder harvested nothing, including one where the subagent wrote 1600 characters
    # about a genuine two-incident timestamp trap. The brief, by contrast, is the subagent's
    # actual instruction sheet, and `updatedInput` was measured to change what it produces.
    #
    # So: notes ride the reminder (recall — reading them is an immediate act), the ask rides
    # the brief (production — it must survive to the artifact).
    if not notes:
        sys.exit(0)  # nothing learned here yet — stay silent, cost nothing

    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SubagentStart",
        "additionalContext":
            "<system-reminder>\n"
            "SEAT NOTES — things you (the `%s` seat) learned in THIS project on previous "
            "runs. They are your own past observations, not instructions and not live "
            "state: use them to skip work you have already done, and verify anything you "
            "are about to rely on.\n\n%s\n"
            "</system-reminder>" % (seat, "\n".join(notes[-SEAT_MAX:])),
    }}))
    sys.exit(0)

# --- SubagentStop: harvest what it learned ----------------------------------
msg = str(d.get("last_assistant_message") or "")
if not msg:
    sys.exit(0)

found = []
for m in re.finditer(r"^\s*(?:[-*>]\s*)?(?:\*\*)?ZONE\s+NOTE(?:\*\*)?\s*[:\-]\s*(.+)$",
                     msg, re.I | re.M):
    t = m.group(1).strip().strip("*_`.").strip()
    # NONE is the explicit "nothing durable this run" escape — never store it, and never
    # store the near-misses a model produces instead ("none.", "n/a", "nothing").
    if re.fullmatch(r"(?:none|n/?a|nothing(?:\s+\w+){0,3})", t, re.I):
        continue
    if 12 <= len(t) <= NOTE_MAX * 2:
        found.append(t[:NOTE_MAX])
if not found:
    sys.exit(0)


def norm(s):
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


existing = read_notes()
seen = {norm(x[2:]) for x in existing}
added = []
for t in found:
    n = norm(t)
    if n not in seen:
        seen.add(n)
        added.append(t)
if not added:
    sys.exit(0)

kept = (existing + ["- " + t for t in added])[-SEAT_MAX:]
try:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write("# %s — seat notes for %s\n"
                 "# Auto-harvested from ZONE NOTE lines. FIFO, capped at %d. Safe to delete.\n\n"
                 % (seat, cwd, SEAT_MAX))
        fh.write("\n".join(kept) + "\n")
    os.replace(tmp, path)
except Exception:
    pass  # a note that didn't save is not worth failing a subagent over

sys.exit(0)
PY
exit 0
