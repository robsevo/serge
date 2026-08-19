#!/usr/bin/env bash
# Serge statusline — model · dir · session tokens · quota gauge · context %.
#
# The roster is all-free (2026-07-07), so a dollar figure is noise; the real
# currency is QUOTA. We show session token volume (from the transcript's real
# usage) plus the daily quota segment cached by quota.sh (refreshed every 5 min
# via budget-watchdog). Dollars appear ONLY if a PAID Bedrock hatch actually
# ran this session (haiku-paid/opus-paid/kimi-coder at their real prices).
# Reads the StatusLine JSON on stdin; jq isn't installed here → python3.
set -uo pipefail
command -v python3 >/dev/null 2>&1 || { printf 'serge'; exit 0; }
input="$(cat)"
# Pass the JSON as argv (NOT stdin): `python3 - <<HEREDOC` already binds stdin to
# the heredoc program, so a piped stdin would be shadowed and never read.
python3 - "$input" <<'PY'
import sys, json, os
try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    print("serge"); sys.exit(0)

tx = d.get("transcript_path") or ""
mdl = d.get("model") or {}
model_disp = mdl.get("display_name") or mdl.get("id") or "?"
cwd = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
base = os.path.basename(cwd.rstrip("/")) or cwd
pct = (d.get("context_window") or {}).get("used_percentage")

# Every roster seat is $0; only the explicit OpenRouter hatches bill ($/1M in, out;
# live prices fetched 2026-07-21 — re-check /api/v1/models if OpenRouter reprices).
# Cache READ ≈ 0.1× input, cache WRITE/creation ≈ 1.25× input (5-min ephemeral).
#
# Keyed by BOTH the seat name and the upstream id, because a transcript records
# whichever one LiteLLM served: naming the seat logs "haiku-paid", but falling
# back into it logs "anthropic/claude-haiku-4.5". Fallback is the path that
# spends money unintentionally, and the seat-name-only table priced it at $0 —
# this line showed nothing through the $6.19 Haiku day of 2026-07-22.
PAID_PRICES = {
    "cheap-paid":  (0.11, 0.80),    # Qwen3-Coder-Next (OpenRouter) — anti-brick rung
    "haiku-paid":  (1.00, 5.00),    # Claude Haiku 4.5 (OpenRouter)
    "sonnet-paid": (2.00, 10.00),   # Claude Sonnet 5 (OpenRouter)
    "opus-paid":   (5.00, 25.00),   # Claude Opus 4.8 (OpenRouter)
    "kimi-coder":  (0.57, 2.85),    # Kimi K2.5 (OpenRouter)
    "qwen/qwen3-coder-next":      (0.11, 0.80),
    "anthropic/claude-haiku-4.5": (1.00, 5.00),
    "anthropic/claude-sonnet-5":  (2.00, 10.00),
    "anthropic/claude-opus-4.8":  (5.00, 25.00),
    "moonshotai/kimi-k2.5":       (0.57, 2.85),
}

paid_total = 0.0
tok_in = tok_out = 0
if tx and os.path.exists(tx):
    try:
        with open(tx, encoding="utf-8") as fh:
            for line in fh:
                if '"assistant"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("type") != "assistant":
                    continue
                m = e.get("message") or {}
                u = m.get("usage") or {}
                it = u.get("input_tokens") or 0
                ot = u.get("output_tokens") or 0
                cr = u.get("cache_read_input_tokens") or 0
                cc = u.get("cache_creation_input_tokens") or 0
                tok_in += it + cr + cc
                tok_out += ot
                pp = PAID_PRICES.get(m.get("model") or "")
                if pp:
                    pin, pout = pp
                    paid_total += (it * pin + ot * pout + cr * pin * 0.1 + cc * pin * 1.25) / 1_000_000
    except Exception:
        pass

def fmt_tok(n):
    return f"{n/1_000_000:.1f}M" if n >= 1_000_000 else (f"{n//1000}k" if n >= 1000 else str(n))

parts = ["\x1b[2mserge\x1b[0m", model_disp, base,
         f"\x1b[2mtok {fmt_tok(tok_in)}/{fmt_tok(tok_out)}\x1b[0m"]

# Daily quota segment — cached by quota.sh (via budget-watchdog, every 5 min).
try:
    qp = os.path.expanduser("~/.serge/monitor/quota-line.txt")
    if os.path.exists(qp) and (os.path.getmtime(qp) > __import__("time").time() - 1200):
        q = open(qp).read().strip()
        if q:
            parts.append(f"\x1b[36m{q}\x1b[0m")
except Exception:
    pass

if paid_total > 0:
    parts.append(f"\x1b[31mPAID ${paid_total:,.2f}\x1b[0m")
if isinstance(pct, (int, float)):
    parts.append(f"ctx {pct:.0f}%")
print("  ".join(p for p in parts if p))
PY
