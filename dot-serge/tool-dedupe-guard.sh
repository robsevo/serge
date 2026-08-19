#!/usr/bin/env bash
# Serge same-step tool-call dedupe — deny duplicate identical tool calls
# issued in ONE assistant step ($0 per call, no LLM).
#
# Ported from MoonshotAI/kimi-code (MIT) toolDedupeService's same-step
# suppression (its cross-step repeat ladder is ~/.serge/tool-repeat-guard.sh).
# When a model emits the same (tool, args) twice in one step — parallel
# tool_use blocks — serge executes both. For Bash that means a mutation
# (git commit, rm, INSERT) runs TWICE. This hook denies every instance after
# the first, with a reason telling the model to use the original's result.
#
# Detection, two layers:
#   1. Same-step sibling check (primary, deterministic): the assistant message
#      holding all of a step's tool_use blocks is in the transcript before
#      execution begins. Find OUR block by tool_use_id; if an identical block
#      appears EARLIER in the same message, we are the duplicate → deny.
#      Block order decides, so parallel hook timing can't misfire, and the
#      first instance is never denied. Cross-step repeats live in a different
#      message → untouched (tool-repeat-guard's territory).
#   2. In-flight lockfile (backstop, 15s TTL): catches a duplicate racing in
#      before the transcript is readable. O_CREAT|O_EXCL per (session, key);
#      cleared on PostToolUse/PostToolUseFailure; stale locks are taken over,
#      so a missed clear (crash, hook timeout) costs at most one 15s window.
#
# Safety:
#   1. Off-switch:  SERGE_TOOL_DEDUPE_DISABLE=1
#   2. Fail open: any parse/read error → allow.
#   3. Exempt polling tools (TaskOutput, Monitor, TaskList, Sleep)
#      + extend via SERGE_TOOL_DEDUPE_EXEMPT="Foo,Bar".
#   4. TTL tunable via SERGE_TOOL_DEDUPE_TTL (seconds, default 15).
#
# Wired in ~/.serge/settings.json as PreToolUse "*" (decide) and
# PostToolUse/PostToolUseFailure "*" (clear lock).
set -uo pipefail

[ "${SERGE_TOOL_DEDUPE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, hashlib, time

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

event = str(d.get("hook_event_name") or "")
tool = str(d.get("tool_name") or "")
if not tool or event not in ("PreToolUse", "PostToolUse", "PostToolUseFailure"):
    sys.exit(0)

EXEMPT = {"TaskOutput", "Monitor", "TaskList", "Sleep"}
EXEMPT |= {t.strip() for t in os.environ.get("SERGE_TOOL_DEDUPE_EXEMPT", "").split(",") if t.strip()}
if tool in EXEMPT:
    sys.exit(0)

def canon(obj):
    try:
        return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str)
    except Exception:
        return str(obj)

sid = str(d.get("session_id") or "nosid")
key = hashlib.sha1((tool + "\x00" + canon(d.get("tool_input"))).encode("utf-8", "ignore")).hexdigest()[:20]
lock = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-tooldedupe-%s-%s.lock" % (hashlib.sha1(sid.encode()).hexdigest()[:12], key),
)

# --- Post events: the executed call releases its in-flight lock -------------
if event in ("PostToolUse", "PostToolUseFailure"):
    try:
        os.unlink(lock)
    except Exception:
        pass
    sys.exit(0)

# --- PreToolUse -------------------------------------------------------------

def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)

# One line, on purpose (2026-08-15). This string has ONE field to live in —
# permissionDecisionReason — and that field is both the model's instruction and
# what the user reads on screen under the denied call. The previous four-sentence
# version explained its own rationale to the model, which the model does not need
# (it needs the instruction) and the user does not want (it is internal
# mechanics). Keep the instruction and the escape hatch; drop the essay.
DUP_REASON = (
    "Duplicate %s call in this step — use the first call's result. "
    "To force a fresh run, change an argument or repeat it in a later step." % tool
)

# 1) Same-step sibling check via the transcript.
tool_use_id = str(d.get("tool_use_id") or "")
tx = d.get("transcript_path") or ""
if tool_use_id and tx and os.path.exists(tx):
    try:
        size = os.path.getsize(tx)
        with open(tx, "rb") as fh:
            if size > 1_048_576:
                fh.seek(size - 1_048_576)
                fh.readline()  # drop partial line
            tail_lines = fh.read().decode("utf-8", "ignore").splitlines()
        my_canon = canon(d.get("tool_input"))
        for line in reversed(tail_lines):
            if tool_use_id not in line or '"assistant"' not in line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") != "assistant":
                continue
            blocks = ((e.get("message") or {}).get("content") or [])
            for b in blocks:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                if b.get("id") == tool_use_id:
                    break  # reached our own block: no earlier identical sibling
                if b.get("name") == tool and canon(b.get("input")) == my_canon:
                    deny(DUP_REASON)
            break  # found our message; verdict reached either way
    except Exception:
        pass  # fail open

# 1.5) Cross-step repeat CEILING (added 2026-08-15 from a real report:
# `/swarm` ran 6 times and nothing stopped it).
#
# WHY THIS EXISTS: the escalation ladder in tool-repeat-guard.sh is a
# PostToolUse hook, so it fires AFTER the call has already run — it can nudge
# (R1 at streak 3, R2 at 5, R3 "write your final response now" at 8) but it can
# never refuse. The same-step check above is PreToolUse and CAN refuse, but only
# sees siblings inside one assistant message. So a model that ignores three
# escalating nudges across separate steps was unstoppable by any hook: measured
# 8/8 identical calls executed, 3/3 cross-step PreToolUse calls allowed.
# This closes that gap by reading the streak the ladder already maintains and
# denying once R3 has been issued and ignored.
#
# Ceiling is 8 — the streak at which R3 already fired. Reaching a 9th identical
# call means three escalating instructions were ignored, so a false positive
# requires nine byte-identical calls with no other activity between them (any
# different call resets the streak to 0 in the ladder's own state).
# Tunable via SERGE_TOOL_REPEAT_CEILING; 0 disables this layer only.
try:
    ceiling = int(os.environ.get("SERGE_TOOL_REPEAT_CEILING", "8") or "8")
except Exception:
    ceiling = 8
if ceiling > 0:
    try:
        # Key must match tool-repeat-guard.sh exactly: full sha1 hexdigest of
        # tool + NUL + canonical args, state file keyed by sha1(sid)[:12].
        repeat_key = hashlib.sha1(
            (tool + "\x00" + canon(d.get("tool_input"))).encode("utf-8", "ignore")
        ).hexdigest()
        state_path = os.path.join(
            os.environ.get("TMPDIR", "/tmp"),
            "serge-toolrepeat-" + hashlib.sha1(sid.encode()).hexdigest()[:12] + ".json",
        )
        with open(state_path) as fh:
            st = json.load(fh)
        if st.get("key") == repeat_key and int(st.get("streak", 0)) >= ceiling:
            deny(
                "This exact %s call has run %d times in a row with no new result. "
                "Stop calling tools and write your response now: state the blocker, "
                "what each attempt established, and what you need from the user. "
                "To force another run, change an argument." % (tool, int(st.get("streak", 0)))
            )
    except Exception:
        pass  # no state file / unreadable / malformed → fail open

# 2) In-flight lockfile backstop.
try:
    ttl = float(os.environ.get("SERGE_TOOL_DEDUPE_TTL", "15") or "15")
except Exception:
    ttl = 15.0
try:
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.close(fd)
except FileExistsError:
    try:
        age = time.time() - os.path.getmtime(lock)
    except Exception:
        age = ttl + 1
    if age < ttl:
        deny(DUP_REASON)
    try:
        os.utime(lock, None)  # stale: take the lock over
    except Exception:
        pass
except Exception:
    pass  # fail open

sys.exit(0)
PY
