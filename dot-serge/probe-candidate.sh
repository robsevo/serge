#!/usr/bin/env bash
# Serge candidate-model acceptance test — does a model actually work FOR US?
#
# WHY: a model's catalog metadata is not evidence. OpenRouter lists
# `cohere/north-mini-code:free` and `openai/gpt-oss-20b:free` with
# supported_parameters containing "tools", and both return HTTP 200 while
# emitting NO tool_calls — which is worse than failing, because the agentic
# loop just stalls. Separately, Cerebras' free `zai-glm-4.7` answers "hi"
# perfectly and hard-caps at 8,192 tokens, while serge's MEDIAN request is
# ~74,700 tokens. Neither failure is visible without probing at real shape.
#
# WHAT: two gates, both of which a candidate must pass.
#   1. CONTEXT — accept a --ctx-tokens-sized request (default 75000, our median)
#   2. TOOLS   — given a tool definition and a prompt that requires it, actually
#                emit a tool_calls entry naming that tool
#
# Usage:
#   ~/.serge/probe-candidate.sh --base https://openrouter.ai/api/v1 \
#       --key-env OPENROUTER_API_KEY --models a,b,c
#   ~/.serge/probe-candidate.sh --base https://api.z.ai/api/paas/v4 \
#       --key-env ZAI_API_KEY --models glm-4.7-flash
#   ~/.serge/probe-candidate.sh --base https://integrate.api.nvidia.com/v1 \
#       --key-env NVIDIA_API_KEY --models deepseek-ai/deepseek-v4-pro
#
# Keys are read from the environment, or from ~/.serge/router.env if present.
# Exit 0 only if every probed model passes both gates.
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
BASE=""; KEY_ENV=""; MODELS=""; CTX_TOKENS=75000
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --base=*) BASE="${1#*=}"; shift ;;
    --key-env) KEY_ENV="${2:-}"; shift 2 ;;
    --key-env=*) KEY_ENV="${1#*=}"; shift ;;
    --models) MODELS="${2:-}"; shift 2 ;;
    --models=*) MODELS="${1#*=}"; shift ;;
    --ctx-tokens) CTX_TOKENS="${2:-75000}"; shift 2 ;;
    --ctx-tokens=*) CTX_TOKENS="${1#*=}"; shift ;;
    -h|--help) sed -n '1,32p' "$0"; exit 0 ;;
    *) echo "probe-candidate: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] && [ -n "$KEY_ENV" ] && [ -n "$MODELS" ] || {
  echo "probe-candidate: --base, --key-env and --models are all required" >&2; exit 2; }
case "$CTX_TOKENS" in ''|*[!0-9]*)
  echo "probe-candidate: --ctx-tokens must be an integer" >&2; exit 2 ;; esac

# Pull the key from router.env if it is not already exported.
if [ -z "${!KEY_ENV:-}" ] && [ -f "$SERGE_HOME/router.env" ]; then
  set -a; . "$SERGE_HOME/router.env" 2>/dev/null; set +a
fi
if [ -z "${!KEY_ENV:-}" ]; then
  echo "probe-candidate: \$$KEY_ENV is not set (and not in router.env)." >&2
  echo "  This provider needs an account first — nothing to probe." >&2
  exit 3
fi

BASE="$BASE" KEY="${!KEY_ENV}" MODELS="$MODELS" CTX_TOKENS="$CTX_TOKENS" python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

base = os.environ["BASE"].rstrip("/")
key = os.environ["KEY"]
models = [m.strip() for m in os.environ["MODELS"].split(",") if m.strip()]
ctx_tokens = int(os.environ["CTX_TOKENS"])
url = base + "/chat/completions"

TOOL = [{
    "type": "function",
    "function": {
        "name": "get_build_status",
        "description": "Get the current CI build status for a branch.",
        "parameters": {
            "type": "object",
            "properties": {"branch": {"type": "string",
                                      "description": "branch name"}},
            "required": ["branch"],
        },
    },
}]

def call(body, timeout=180):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key,
                 # Some providers 403 an unidentified client.
                 "User-Agent": "serge-probe/1.0"})
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8", "replace")), None, time.monotonic() - t0
    except urllib.error.HTTPError as e:
        return None, "HTTP %s: %s" % (e.code, e.read().decode("utf-8", "replace")[:200]), time.monotonic() - t0
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, e), time.monotonic() - t0

def gate_context(model):
    """Accept a production-shaped request (~ctx_tokens)."""
    fill = "the quick brown fox jumps over the lazy dog. " * max(1, ctx_tokens // 10)
    payload, err, secs = call({"model": model, "max_tokens": 8,
                               "messages": [{"role": "user",
                                             "content": fill + " Reply OK."}]})
    if err:
        return False, err, secs
    used = (payload.get("usage") or {}).get("prompt_tokens")
    return True, "accepted %s prompt tokens" % (format(used, ",") if used else "?"), secs

def gate_tools(model):
    """Actually emit a tool_call, not merely advertise support."""
    payload, err, secs = call({
        "model": model, "max_tokens": 256, "tools": TOOL,
        "tool_choice": "auto",
        "messages": [{"role": "user",
                      "content": "Is the build passing on the 'release' branch? "
                                 "Use the tool. Do not guess."}]})
    if err:
        return False, err, secs
    try:
        msg = payload["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return False, "no choices in response", secs
    calls = msg.get("tool_calls") or []
    if not calls:
        body = (msg.get("content") or "").strip()[:70]
        return False, "200 but NO tool_calls (answered in prose: %r)" % body, secs
    name = ((calls[0] or {}).get("function") or {}).get("name")
    if name != "get_build_status":
        return False, "called the wrong tool: %r" % name, secs
    return True, "emitted tool_call %s" % name, secs

def retrying(gate, model):
    """Free pools are flaky — retry once before declaring a model unfit.

    Measured 2026-07-29: nvidia/nemotron-3-ultra-550b-a55b:free returned "no
    choices in response" on one attempt and emitted a correct tool_call on the
    next. Without this retry the probe rejects a perfectly good model, which is
    the expensive direction to be wrong in.
    """
    ok, why, secs = gate(model)
    if ok:
        return ok, why, secs
    time.sleep(3)
    ok2, why2, secs2 = gate(model)
    if ok2:
        return True, why2 + " (passed on retry; first attempt: %s)" % why[:60], secs2
    return False, why2 + " (twice)", secs2

print("Candidate probe · %s · ctx gate %s tokens" % (base, format(ctx_tokens, ",")))
failed = []
for model in models:
    print("\n== %s" % model)
    ok_ctx, why_ctx, s1 = retrying(gate_context, model)
    print("   context  %-4s %s (%.1fs)" % ("PASS" if ok_ctx else "FAIL", why_ctx, s1))
    ok_tools, why_tools, s2 = retrying(gate_tools, model)
    print("   tools    %-4s %s (%.1fs)" % ("PASS" if ok_tools else "FAIL", why_tools, s2))
    if not (ok_ctx and ok_tools):
        failed.append(model)

print("")
if failed:
    print("REJECTED (%d): %s" % (len(failed), ", ".join(failed)))
    print("A model failing either gate cannot hold a serge seat.")
    sys.exit(1)
print("All %d candidate(s) passed both gates." % len(models))
sys.exit(0)
PY
