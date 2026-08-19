#!/usr/bin/env bash
# Serge free-tier scanner — weekly probe for roster-relevant provider changes.
#
# WHY: the roster was hand-probed on 2026-07-07 and providers move constantly —
# Mistral ships new models monthly, Cerebras rotates its catalog, Google shuffles
# free quotas, OpenRouter's :free set churns. Nobody remembers to re-check, so
# newly-free stronger models go unused (exactly how Magistral/Devstral sat
# unnoticed until 2026-07-10).
#
# WHAT (per provider with a key in router.env):
#   1. Fetch the model list (Mistral / Cerebras / Gemini / OpenRouter-:free-only).
#   2. Diff against ~/.serge/monitor/model-catalog.json; NEW or REMOVED ids →
#      one NOTIFICATIONS.md line (the session-start loader surfaces it).
#      First run per provider seeds silently. Fetch failure → keep old state,
#      no diff, no alarm (fail-safe).
#   3. Gemini Pro probe: the free tier currently 429s every Pro variant. Try ONE
#      tiny generateContent on the newest Pro id in the list; HTTP 200 → notify
#      LOUDLY (a free Pro-class brain would be a major roster upgrade). Costs
#      nothing when it fails; one request if it ever succeeds.
#
# Wired as ~/.config/systemd/user/serge-free-tier-scanner.{service,timer} (weekly).
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
RENV="$SERGE_HOME/router.env"
getkey() { grep -E "^$1=" "$RENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'\r'; }

MISTRAL_KEY="$(getkey MISTRAL_API_KEY)" \
CEREBRAS_KEY="$(getkey CEREBRAS_API_KEY)" \
GEMINI_KEY="$(getkey GEMINI_API_KEY)" \
OPENROUTER_KEY="$(getkey OPENROUTER_API_KEY)" \
SERGE_HOME="$SERGE_HOME" \
python3 - <<'PY'
import json, os, time, urllib.request, urllib.error

home = os.environ["SERGE_HOME"]
mon = os.path.join(home, "monitor"); os.makedirs(mon, exist_ok=True)
state_p = os.path.join(mon, "model-catalog.json")
log_p = os.path.join(mon, "free-tier-scanner.log")
notif_p = os.path.join(home, "NOTIFICATIONS.md")
today = time.strftime("%Y-%m-%d")

def log(msg):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        with open(log_p, "a") as f: f.write(f"{stamp}  {msg}\n")
    except OSError: pass

def get(url, headers=None, timeout=30):
    # Cerebras (Cloudflare WAF) 403s Python-urllib's default User-Agent; curl's passes.
    h = {"User-Agent": "curl/8.7.1", **(headers or {})}
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def fetch(provider):
    """Return sorted model-id list or None on any failure."""
    try:
        if provider == "mistral":
            k = os.environ.get("MISTRAL_KEY")
            if not k: return None
            d = get("https://api.mistral.ai/v1/models", {"Authorization": f"Bearer {k}"})
            return sorted({m["id"] for m in d["data"]})
        if provider == "cerebras":
            k = os.environ.get("CEREBRAS_KEY")
            if not k: return None
            d = get("https://api.cerebras.ai/v1/models", {"Authorization": f"Bearer {k}"})
            return sorted({m["id"] for m in d["data"]})
        if provider == "gemini":
            k = os.environ.get("GEMINI_KEY")
            if not k: return None
            ids, tok = set(), ""
            for _ in range(3):
                url = f"https://generativelanguage.googleapis.com/v1beta/models?key={k}&pageSize=1000"
                if tok: url += f"&pageToken={tok}"
                d = get(url)
                ids |= {m["name"].removeprefix("models/") for m in d.get("models", [])}
                tok = d.get("nextPageToken") or ""
                if not tok: break
            return sorted(ids)
        if provider == "openrouter-free":
            k = os.environ.get("OPENROUTER_KEY")
            if not k: return None
            d = get("https://openrouter.ai/api/v1/models", {"Authorization": f"Bearer {k}"})
            return sorted({m["id"] for m in d["data"]
                           if m.get("pricing", {}).get("prompt") == "0"
                           and m.get("pricing", {}).get("completion") == "0"})
    except Exception as e:  # noqa: BLE001 — any failure = skip provider this week
        log(f"{provider}: fetch failed ({type(e).__name__}: {str(e)[:100]})")
        return None

try:
    state = json.load(open(state_p))
except Exception:
    state = {}

notes = []
for prov in ("mistral", "cerebras", "gemini", "openrouter-free"):
    cur = fetch(prov)
    if cur is None:
        continue
    old = state.get(prov)
    if old is None:
        log(f"{prov}: seeded with {len(cur)} models")
    else:
        new = sorted(set(cur) - set(old))
        gone = sorted(set(old) - set(cur))
        if new or gone:
            frag = []
            if new: frag.append("NEW: " + ", ".join(new[:8]) + ("…" if len(new) > 8 else ""))
            if gone: frag.append("removed: " + ", ".join(gone[:5]) + ("…" if len(gone) > 5 else ""))
            notes.append(f"{prov} — {'; '.join(frag)}")
            log(f"{prov}: {'; '.join(frag)}")
        else:
            log(f"{prov}: no change ({len(cur)} models)")
    state[prov] = cur

# Kimi K3 free-route watch (added 2026-07-18, user request): K3 released
# 2026-07-16 (#1 Frontend Code Arena), weights drop ~07-27 — free hosts
# typically follow within days. The generic diff above would mention it, but
# this fires a LOUD dedicated line naming the pre-staged seat flip
# (litellm.yaml "kimi3-coder" block + agents/frontend.md note).
kimi_free = sorted(m for m in state.get("openrouter-free", [])
                   if "kimi" in m.lower() or "moonshot" in m.lower())
if kimi_free:
    notes.append(f"🎯 KIMI FREE ROUTE LIVE: {', '.join(kimi_free)} — flip the "
                 "pre-staged kimi3-coder block in litellm.yaml and bind "
                 "agents/frontend.md to it (see the block's comment)")
    log(f"KIMI WATCH HIT: {kimi_free}")

# Gemini Pro free probe — newest Pro id, 1-token request; 200 = jackpot.
gk = os.environ.get("GEMINI_KEY")
pros = sorted(m for m in state.get("gemini", []) if "-pro" in m and m.startswith("gemini-")
              and "vision" not in m and "embed" not in m)
if gk and pros:
    target = pros[-1]
    body = json.dumps({"contents": [{"parts": [{"text": "hi"}]}],
                       "generationConfig": {"maxOutputTokens": 1}}).encode()
    try:
        req = urllib.request.Request(
            f"https://generativelanguage.googleapis.com/v1beta/models/{target}:generateContent?key={gk}",
            data=body, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=30)
        notes.append(f"gemini — {target} answered on the FREE tier (Pro-class!) — "
                     "re-probe quotas and consider promoting the brain seats")
        log(f"PRO PROBE HIT: {target} succeeded on free tier")
    except urllib.error.HTTPError as e:
        log(f"pro probe: {target} → HTTP {e.code} (expected while Pro is paid-only)")
    except Exception as e:  # noqa: BLE001
        log(f"pro probe: {target} skipped ({type(e).__name__})")

json.dump(state, open(state_p, "w"), indent=1)

if notes:
    with open(notif_p, "a") as f:
        for n in notes:
            f.write(f"- [ ] {today} free-tier-scanner: {n} — roster candidates? (litellm.yaml)\n")
PY
