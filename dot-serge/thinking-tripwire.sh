#!/usr/bin/env bash
# Serge thinking tripwire — daily probe that reasoning actually fires.
#
# WHY: on 2026-07-10 we found SERGE_THINKING_SEATS (set for the old Bedrock
# Anthropic roster) had been silently SUPPRESSING all extended thinking on the
# free seats since the 07-07/07-09 roster flip — LiteLLM drops the native
# `thinking` param for gemini/ and mistral/, and nothing noticed for 3 days.
# This class of failure (roster/config drift quietly killing reasoning depth)
# is invisible in normal use, so we probe for it explicitly.
#
# WHAT: for each seat in SERGE_TRIPWIRE_SEATS, send one small reasoning
# question with reasoning_effort=high (exactly the dial the shim now uses for
# free seats) and check the response carries evidence of thinking:
# reasoning_content, thinking_blocks, or usage reasoning_tokens > 0.
#   - 200 + no thinking evidence  → seat is SHALLOW → notify via
#     NOTIFICATIONS.md (once per ok→shallow transition; the SessionStart
#     loader surfaces it) + log.
#   - transport error / 429 / 5xx → "unreachable": log only, keep prior
#     state (quota exhaustion at day's end is normal, not a thinking bug).
# Note: LiteLLM fallbacks may serve a probe when the primary rung is down —
# the tripwire measures what the SEAT returns, which is the user-visible
# property we care about.
#
# Calibrated 2026-07-10 (all healthy seats return reasoning_content):
#   pro-coder (Gemini 3.1 Flash-Lite) 1108B · think-coder (Magistral) 2146B ·
#   qwen-coder (gpt-oss-120b) 371B · cloud-brain (Gemini 3.5 Flash, same
#   provider path as pro-coder). local-coder (Mistral Large) is a NON-reasoner
#   by design — deliberately not probed.
# QUOTA: one probe/day/seat; cloud-brain's costs 1 of its ~20/day requests.
#
# Wired as ~/.config/systemd/user/serge-thinking-tripwire.{service,timer}
# (daily). Tune seats with SERGE_TRIPWIRE_SEATS; disable by stopping the timer.
#
# SEAT LIST (fixed 2026-08-16): local-coder was MISSING from the default probe
# set for as long as this script has existed — it appears twice in the whole log
# while four lesser seats are probed every run. It is the workhorse: router_
# settings records that ~90%% of turns request it. Probing everything except the
# seat that answers almost every question is how a shallow workhorse would go
# unnoticed indefinitely, which is the exact class of failure this file was
# written to catch.
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
MON="$SERGE_HOME/monitor"
mkdir -p "$MON" 2>/dev/null || true

SERGE_TRIPWIRE_SEATS="${SERGE_TRIPWIRE_SEATS:-local-coder,pro-coder,think-coder,qwen-coder,cloud-brain}" \
SERGE_TRIPWIRE_URL="${SERGE_TRIPWIRE_URL:-http://localhost:4000/v1/chat/completions}" \
SERGE_HOME="$SERGE_HOME" \
python3 - <<'PY'
import json, os, time, urllib.request, urllib.error

home   = os.environ["SERGE_HOME"]
url    = os.environ["SERGE_TRIPWIRE_URL"]
seats  = [s.strip() for s in os.environ["SERGE_TRIPWIRE_SEATS"].split(",") if s.strip()]
mon    = os.path.join(home, "monitor")
state_p = os.path.join(mon, ".thinking-tripwire")
log_p   = os.path.join(mon, "thinking-tripwire.log")
notif_p = os.path.join(home, "NOTIFICATIONS.md")
today   = time.strftime("%Y-%m-%d", time.gmtime())

def log(msg):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        with open(log_p, "a") as f:
            f.write(f"{stamp}  {msg}\n")
    except OSError:
        pass

def load_state():
    try:
        return dict(ln.split("=", 1) for ln in open(state_p).read().split() if "=" in ln)
    except OSError:
        return {}

def save_state(st):
    try:
        with open(state_p, "w") as f:
            f.write("\n".join(f"{k}={v}" for k, v in sorted(st.items())) + "\n")
    except OSError:
        pass

QUESTION = ("A bat and ball cost $1.10 total. The bat costs $1 more than the "
            "ball. What does the ball cost? Answer with just the amount.")

def probe(seat):
    """Returns 'deep' | 'shallow' | 'unreachable'."""
    body = json.dumps({
        "model": seat,
        "messages": [{"role": "user", "content": QUESTION}],
        "max_tokens": 2048,
        "reasoning_effort": "high",
    }).encode()
    req = urllib.request.Request(url, data=body, headers={
        "Content-Type": "application/json",
        "Authorization": "Bearer sk-noop",
    })
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            r = json.load(resp)
    except Exception as e:  # noqa: BLE001 — any transport/HTTP/JSON failure = unreachable
        log(f"{seat}: unreachable ({type(e).__name__}: {str(e)[:120]})")
        return "unreachable"
    if r.get("error"):
        log(f"{seat}: unreachable (error payload: {str(r['error'])[:120]})")
        return "unreachable"
    try:
        msg = r["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        log(f"{seat}: unreachable (malformed response)")
        return "unreachable"
    rc  = msg.get("reasoning_content") or ""
    tb  = msg.get("thinking_blocks") or []
    rt  = ((r.get("usage") or {}).get("completion_tokens_details") or {}).get("reasoning_tokens") or 0
    if len(rc) > 0 or len(tb) > 0 or rt > 0:
        log(f"{seat}: deep (reasoning_content={len(rc)}B, thinking_blocks={len(tb)}, reasoning_tokens={rt})")
        return "deep"
    log(f"{seat}: SHALLOW — 200 OK but no reasoning evidence (content={str(msg.get('content'))[:60]!r})")
    return "shallow"

state = load_state()
newly_shallow = []
for seat in seats:
    status = probe(seat)
    prev = state.get(seat, "deep")
    if status == "unreachable":
        continue  # keep prior state; not a thinking verdict
    if status == "shallow" and prev != "shallow":
        newly_shallow.append(seat)
    if status == "deep" and prev == "shallow":
        log(f"{seat}: recovered (shallow -> deep)")
    state[seat] = status
    time.sleep(2)  # stay well under rpm guards

save_state(state)

if newly_shallow:
    line = (f"- [ ] {today} thinking-tripwire: seat(s) {', '.join(newly_shallow)} "
            "returned NO reasoning content on a reasoning probe — thinking may have "
            "been silently dropped (roster/config drift? check SERGE_THINKING_SEATS, "
            "litellm.yaml, provider changes). Details: ~/.serge/monitor/thinking-tripwire.log\n")
    try:
        with open(notif_p, "a") as f:
            f.write(line)
    except OSError:
        pass
PY
