#!/usr/bin/env bash
# StopFailure hook — fires when a turn dies on an API error (retries already
# exhausted). Since 2026-07-20 this is no longer fire-and-forget: outputting
# {"decision":"block","reason":"..."} asks the core to CONTINUE the session.
# The core honors it only for transient error classes (rate_limit / unknown),
# on the main thread, capped per user turn (SERGE_STOPFAILURE_CONTINUE_CAP,
# default 3) — auth/billing/invalid_request failures always terminate.
#
# This hook owns the BACKOFF: it sleeps before answering (the core awaits it),
# honoring any "retry in Ns"/retryDelay hint in error_details, clamped to
# [5, 90]s, defaults rate_limit=20s / unknown=8s. It also keeps its own
# per-session continuation counter as a second cap layer.
#
# Also still writes the legacy sentinel for external watchers.
#
# Off-switch: SERGE_STOPFAILURE_CONTINUE_DISABLE=1 (sentinel only, no block).
set -uo pipefail

input="$(cat)"

SENTINEL="${SERGE_STOP_FAILURE_SENTINEL:-$HOME/.serge/stop-failure.sentinel}" \
python3 - "$input" <<'PY'
import sys, json, os, re, time, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

sid = str(d.get("session_id") or "unknown")
err = str(d.get("error") or "unknown")

# WHERE THE ERROR TEXT ACTUALLY IS (2026-08-14). This read `error_details`
# alone, and the core does not send that key: a StopFailure payload carries
# exactly cwd, error, hook_event_name, last_assistant_message, session_id,
# transcript_path. So `details` was ALWAYS "" and every hint regex below —
# plus the whole cooldown ceiling branch — matched an empty string and had
# never once fired in production. The 900 s router cooldown it was written for
# sailed straight through to the default 20 s backoff.
#
# `last_assistant_message` is the in-band field that holds the rendered API
# error, same lesson as the stall-nudge race: read the payload, not a field
# name that sounds right. error_details is kept first so a future core that
# does send it still wins.
details = str(d.get("error_details") or d.get("last_assistant_message") or "")

# Opt-in payload dump. The hint regexes below can only match what the core
# actually sends, and that shape is not documented anywhere — dump it rather
# than guess. SERGE_STOPFAILURE_DEBUG=<path>.
_dbg = os.environ.get("SERGE_STOPFAILURE_DEBUG")
if _dbg:
    try:
        with open(_dbg, "a") as fh:
            fh.write(json.dumps({"keys": sorted(d.keys()), "error": err,
                                 "details": details[:600]}) + "\n")
    except Exception:
        pass

# Legacy sentinel (kept for external watchers / headless wrappers).
try:
    with open(os.environ.get("SENTINEL", os.path.expanduser("~/.serge/stop-failure.sentinel")), "w") as fh:
        fh.write(sid)
except Exception:
    pass

if os.environ.get("SERGE_STOPFAILURE_CONTINUE_DISABLE", "0") == "1":
    sys.exit(0)

# Only transient classes get a continuation request (core enforces this too).
if err not in ("rate_limit", "unknown"):
    sys.exit(0)

# Per-session cap (second layer; core caps per user turn).
try:
    cap = int(os.environ.get("SERGE_STOPFAILURE_SESSION_CAP", "6"))
except Exception:
    cap = 6
cntf = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-stopfailure-" + hashlib.sha1(sid.encode()).hexdigest()[:12] + ".cnt",
)
try:
    n = int(open(cntf).read().strip() or "0")
except Exception:
    n = 0
if n >= cap:
    sys.exit(0)
try:
    with open(cntf, "w") as fh:
        fh.write(str(n + 1))
except Exception:
    pass

# Backoff: honor an upstream retry hint if present, else per-class default.
#
# The hint patterns must cover how the ROUTER phrases it, not just the upstream
# provider. Measured 2026-08-02: LiteLLM's all-deployments-cold error reads
#   "No deployments available for selected model, Try again in 900 seconds."
# which matched NEITHER pattern, so hint=None, err="unknown" -> default 8s. The core
# then burned all 3 continuations in ~24s against a 900s cooldown, every one of them
# guaranteed to fail before it was sent.
hint = None
for pat in (r"retry in ([0-9]+(?:\.[0-9]+)?)\s*s",
            r"try again in ([0-9]+(?:\.[0-9]+)?)\s*(?:s\b|sec)",
            r'"retryDelay"\s*:\s*"([0-9]+(?:\.[0-9]+)?)s"',
            r'"retry_after"\s*:\s*([0-9]+(?:\.[0-9]+)?)',
            r"retry[- ]after:\s*([0-9]+(?:\.[0-9]+)?)"):
    m = re.search(pat, details, re.I)
    if m:
        try:
            hint = float(m.group(1))
            break
        except Exception:
            hint = None

# A cooldown longer than we are willing to sleep must NOT be retried. Continuing
# early is not a partial win — it consumes one of the 3 capped continuations on a
# request the server has already told us it will refuse. Fail honestly instead, and
# say when the seat comes back, so the human can switch seats or wait deliberately.
SLEEP_CEILING = float(os.environ.get("SERGE_STOPFAILURE_MAX_SLEEP", "90"))
if hint is not None and hint > SLEEP_CEILING:
    # EXIT 0 — no decision. `{"decision": "block"}` is this hook's CONTINUE
    # signal (see the header), so the previous version of this branch asked the
    # core to continue while its own `reason` prose said "STOP — do not retry".
    # The prose never reached anyone: delivering it needs a model call, that call
    # hit the same cooled router, StopFailure fired again, and the loop ran to the
    # cap. Measured 2026-08-14 against a 900 s cooldown: 4 requests at 20 s
    # intervals, every one guaranteed to fail before it was sent.
    #
    # Saying nothing here ends the turn on the engine's own error message, which
    # now names the cooldown, the likely cause (a key, not traffic) and the fix.
    # A hook cannot both stop the turn and narrate why — the engine message is
    # the one that actually reaches the user.
    sys.exit(0)

delay = hint if hint is not None else (20.0 if err == "rate_limit" else 8.0)
delay = max(5.0, min(delay, SLEEP_CEILING))
if os.environ.get("SERGE_STOPFAILURE_NO_SLEEP", "0") != "1":  # test escape hatch
    time.sleep(delay)

reason = (
    "The previous turn was terminated by a transient API failure "
    f"({err}), not by anything you did wrong. The provider has had "
    f"{int(delay)}s to recover. Resume the task exactly where it stopped: "
    "briefly re-establish state (check your last completed step) and "
    "continue. Do not restart finished work and do not apologize for the "
    "interruption."
)
print(json.dumps({"decision": "block", "reason": reason}))
PY
