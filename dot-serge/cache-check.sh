#!/usr/bin/env bash
# Serge cache-health probe — does prompt caching actually fire for serge's traffic?
#
# Serge resends a large stable prefix (~8K-token constitution) every turn. If it
# caches, repeated input bills at ~0.1x; if not, you pay full input every turn.
# OpenRouter usage in a normal response often UNDER-reports cached tokens, so this
# script gives a DEFINITIVE answer by querying OpenRouter's generation-stats
# endpoint (the billing source of truth: native_tokens_cached + cache_discount).
#
# Two probes:
#   [1] via the LiteLLM router (mimics serge's exact path) — reports usage.cached.
#   [2] DIRECT to OpenRouter on the real upstream model + generation-stats lookup —
#       definitive: did the 2nd identical request bill cached tokens / a discount?
#
# Usage:   ~/.serge/cache-check.sh [alias]     (default: local-coder = workhorse)
#          ~/.serge/cache-check.sh cloud-brain (Opus seat; ~$0.12 for the probe)
set -uo pipefail

ROUTER_URL="${SERGE_CACHE_URL:-http://localhost:4000/v1/chat/completions}"
ALIAS="${1:-${SERGE_CACHE_MODEL:-local-coder}}"
SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }

# Pull OPENROUTER_API_KEY from router.env (or env) for the direct/definitive probe.
if [ -z "${OPENROUTER_API_KEY:-}" ] && [ -f "$SERGE_HOME/router.env" ]; then
  # shellcheck disable=SC1091
  set -a; . "$SERGE_HOME/router.env" 2>/dev/null || true; set +a
fi

echo "Cache probe → alias=$ALIAS  router=$ROUTER_URL"

ROUTER_URL="$ROUTER_URL" ALIAS="$ALIAS" SERGE_HOME="$SERGE_HOME" \
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" python3 - <<'PY'
import os, re, json, time, urllib.request

ROUTER_URL = os.environ["ROUTER_URL"]
ALIAS = os.environ["ALIAS"]
HOME = os.environ["SERGE_HOME"]
OR_KEY = os.environ.get("OPENROUTER_API_KEY", "").strip()

# A large, STABLE prefix (~6K+ tokens). Identical bytes across calls so the 2nd is
# a pure cache-read candidate. cache_control marks it for Anthropic; DeepSeek/GLM
# auto-cache and ignore the hint.
PREFIX = ("You are a coding assistant. Reference rules follow. " +
          ("RULE: prefer minimal diffs; verify before claiming success; never hardcode "
           "secrets; ground every claim in a tool result; keep edits targeted. ") * 360)

def resolve_upstream(alias):
    """alias (local-coder) -> openrouter upstream id (deepseek/deepseek-v4-flash) from litellm.yaml."""
    path = os.path.join(HOME, "litellm.yaml")
    try:
        txt = open(path).read()
    except Exception:
        return None
    # crude block parse: model_name: X ... model: openrouter/Y
    name, found = None, {}
    for line in txt.splitlines():
        m = re.match(r"\s*-?\s*model_name:\s*(\S+)", line)
        if m: name = m.group(1).strip(); continue
        m = re.match(r"\s*model:\s*openrouter/(\S+)", line)
        if m and name: found[name] = m.group(1).strip()
    return found.get(alias)

def post(url, body, key=None):
    headers = {"Content-Type": "application/json"}
    if key: headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)

def usage_cached(u):
    if not isinstance(u, dict): return None
    ptd = u.get("prompt_tokens_details") or {}
    return (ptd.get("cached_tokens") or u.get("cache_read_input_tokens")
            or u.get("cached_tokens"))

def chat_body(model, cache_control=False):
    sys_content = ([{"type": "text", "text": PREFIX, "cache_control": {"type": "ephemeral"}}]
                   if cache_control else PREFIX)
    return {"model": model, "max_tokens": 1, "temperature": 0,
            "messages": [{"role": "system", "content": sys_content},
                         {"role": "user", "content": "Reply with: ok"}],
            "usage": {"include": True}}

# ── [1] via the router (serge's exact path) ─────────────────────────────────
print("\n[1] via LiteLLM router (mimics serge) …")
try:
    r1 = post(ROUTER_URL, chat_body(ALIAS))
    r2 = post(ROUTER_URL, chat_body(ALIAS))
    for lbl, r in (("#1 write", r1), ("#2 read ", r2)):
        u = r.get("usage") or {}
        print(f"    {lbl}: prompt_tokens={u.get('prompt_tokens')} cached={usage_cached(u)}")
    router_cached = usage_cached((r2.get("usage") or {}))
except Exception as e:
    print(f"    ✗ router probe failed: {e}")
    router_cached = None

# ── [2] DIRECT to OpenRouter + generation stats (definitive) ────────────────
print("\n[2] DIRECT to OpenRouter + generation-stats (definitive) …")
upstream = resolve_upstream(ALIAS)
if not upstream:
    print(f"    ✗ could not resolve '{ALIAS}' -> upstream model from litellm.yaml; skipping.")
elif not OR_KEY:
    print("    ✗ OPENROUTER_API_KEY not found (router.env); skipping definitive probe.")
else:
    print(f"    upstream model: {upstream}")
    is_anthropic = upstream.startswith("anthropic/")
    try:
        d1 = post("https://openrouter.ai/api/v1/chat/completions", chat_body(upstream, cache_control=is_anthropic), OR_KEY)
        d2 = post("https://openrouter.ai/api/v1/chat/completions", chat_body(upstream, cache_control=is_anthropic), OR_KEY)
        def stats(gen_id):
            url = "https://openrouter.ai/api/v1/generation?id=" + urllib.parse.quote(gen_id)
            for _ in range(6):  # stats lag a beat after the request
                try:
                    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + OR_KEY})
                    with urllib.request.urlopen(req, timeout=30) as r:
                        return (json.load(r) or {}).get("data") or {}
                except Exception:
                    time.sleep(1.2)
            return {}
        import urllib.parse
        for lbl, d in (("#1 write", d1), ("#2 read ", d2)):
            gid = d.get("id", "")
            s = stats(gid) if gid else {}
            print(f"    {lbl}: id={gid or '?'} native_prompt={s.get('native_tokens_prompt')} "
                  f"native_cached={s.get('native_tokens_cached')} cache_discount={s.get('cache_discount')}")
        s2 = stats(d2.get("id", "")) if d2.get("id") else {}
        nc = s2.get("native_tokens_cached")
        cd = s2.get("cache_discount")
        print("\n" + "="*64)
        fired = (isinstance(nc, (int, float)) and nc > 0) or (isinstance(cd, (int, float)) and cd not in (0, None) and cd < 0) or (isinstance(cd,(int,float)) and cd>0)
        if (isinstance(nc,(int,float)) and nc>0):
            print(f"✓ DEFINITIVE: caching FIRES — request #2 billed {nc} cached input tokens"
                  + (f", cache_discount={cd}." if cd is not None else "."))
            print("  Serge's repeated prefix bills at the cheap cache-read rate. No action needed.")
        elif (isinstance(cd,(int,float)) and cd):
            print(f"✓ DEFINITIVE: caching FIRES — cache_discount={cd} on request #2 (provider applied a cache rebate).")
        else:
            print("✗ DEFINITIVE: NO caching on request #2 (native_tokens_cached="
                  f"{nc}, cache_discount={cd}).")
            print("  You pay FULL input price every turn. Fixes:")
            if is_anthropic:
                print("   • Anthropic via OpenRouter needs cache_control breakpoints on the stable")
                print("     prefix — ensure serge's engine sends them (it may not by default).")
            else:
                print("   • This provider/route didn't cache. Pin a provider that supports prompt")
                print("     caching (OpenRouter provider routing), or accept full input pricing.")
    except Exception as e:
        print(f"    ✗ direct probe failed: {e}")

# ── reconcile ───────────────────────────────────────────────────────────────
print("\nNote: the router probe [1] reflects serge's ACTUAL traffic; [2] is the")
print("provider's billed truth. If [2] caches but [1] shows 0, the provider can")
print("cache but serge's request shape isn't triggering it (fixable in the engine).")
PY