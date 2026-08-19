#!/usr/bin/env bash
# Serge quota gauge — the roster is all-free, so the real currency is QUOTA,
# not dollars. Scans today's transcripts and aggregates per-provider usage:
#   BRAIN   cloud-brain/bedrock-brain  → gemini-3.5-flash   (~20 req/day)
#   GEM-3F  free-flash3                → gemini-3-flash-prev (~20 req/day)
#   GEM-25  free-flash25               → gemini-2.5-flash    (~20 req/day)
#   LITE    pro-coder/free-flash       → gemini-3.1-f-lite   (big pool)
#   MISTRAL local/free-large/think/fast coder               (~1B tok/MONTH)
#   CEREB   qwen/glm-coder, free-scout/brain                (~1M tok/day)
#   OPENRTR free-qwen                                       (~50 req/day)
#   PAID    haiku-paid/opus-paid/kimi-coder                 (BILLS — tripwire)
#
# CAVEAT: attribution is by REQUESTED seat (the transcript records the model
# group; LiteLLM-side fallbacks are invisible), and "today" is the LOCAL date
# while providers reset on their own clocks — treat this as a fuel gauge, not
# an odometer. Writes:
#   ~/.serge/monitor/quota-today.txt  (pretty report — /cost shows it)
#   ~/.serge/monitor/quota-line.txt   (compact segment — statusline shows it)
# Called by budget-watchdog.sh every 5 min and by cost.sh on demand.
set -uo pipefail
SERGE_HOME="${SERGE_HOME:-$HOME/.serge}" python3 - <<'PY'
import calendar, json, os, time, glob

home = os.environ["SERGE_HOME"]
mon  = os.path.join(home, "monitor")
os.makedirs(mon, exist_ok=True)
today = time.strftime("%Y-%m-%d")          # local date
utoday = time.strftime("%Y-%m-%d", time.gmtime())   # UTC date — what OpenRouter bills on

# Files are pre-filtered by mtime to keep the scan cheap. That filter used to
# demand mtime == LOCAL today, which opened a nightly blind window (fixed
# 2026-07-22): between 20:00 and midnight EDT a turn bills to OpenRouter's
# UTC "today" but its file is stamped local "yesterday", so it was skipped
# entirely. The $6.19 Haiku day landed almost wholly inside that window and
# the gauge read 0 req. Take the EARLIER of the two midnights as the cutoff
# and let the per-entry timestamp check below do the precise filtering.
# NB: mktime() reads a struct as LOCAL time, so it cannot express UTC midnight
# (both date strings are the same text for most of the day and would collapse
# to the same instant). calendar.timegm() is the UTC-correct inverse.
_scan_cutoff = min(
    time.mktime(time.strptime(today, "%Y-%m-%d")),          # local midnight
    calendar.timegm(time.strptime(utoday, "%Y-%m-%d")),     # UTC midnight
)

BUCKETS = [
    # key, label, seats, kind('req'|'tok'), cap (None = big/unknown)
    ("brain",   "brain (Gemini 3.5 Flash)",  {"cloud-brain", "bedrock-brain"}, "req", 20),
    ("gem3f",   "Gemini 3 Flash bucket",     {"free-flash3"},                  "req", 20),
    ("gem25",   "Gemini 2.5 Flash bucket",   {"free-flash25"},                 "req", 20),
    ("lite",    "Gemini 3.1 Flash-Lite",     {"pro-coder", "free-flash"},      "req", None),
    ("mistral", "Mistral pool (tokens)",     {"local-coder", "free-large", "think-coder", "fast-coder"}, "tok", None),
    ("cereb",   "Cerebras pool (tokens)",    {"qwen-coder", "glm-coder", "free-scout", "free-brain"},    "tok", 1_000_000),
    ("openrtr", "OpenRouter :free rung",     {"free-qwen"},                    "req", 50),
    # SERVED ids belong here too (added 2026-07-22). The transcript records what
    # LiteLLM actually served: naming the seat logs "haiku-paid", but FALLING
    # BACK into it logs the upstream id "anthropic/claude-haiku-4.5". Fallback
    # is the unintentional path — the one worth a ⚠ BILLING flag — and the
    # seat-name-only set missed it, so this gauge read "0 req" through a $6.19
    # day of pure fallback traffic.
    ("paid",    "PAID hatches (OpenRouter)",
     {"haiku-paid", "sonnet-paid", "opus-paid", "kimi-coder", "cheap-paid",
      "anthropic/claude-haiku-4.5", "anthropic/claude-sonnet-5",
      "anthropic/claude-opus-4.8", "moonshotai/kimi-k2.5",
      "qwen/qwen3-coder-next"}, "req", 0),
]
seat2key = {s: k for k, _, seats, _, _ in BUCKETS for s in seats}
agg = {k: {"req": 0, "tok": 0} for k, *_ in BUCKETS}

for path in glob.glob(os.path.join(home, "projects", "**", "*.jsonl"), recursive=True):
    try:
        if os.path.getmtime(path) < _scan_cutoff:
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"assistant"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("type") != "assistant":
                    continue
                ts = e.get("timestamp") or ""
                # per-entry date filter when available (files can span days)
                if ts[:10] and ts[:10] != today and ts[:10] != utoday:
                    continue
                m = e.get("message") or {}
                key = seat2key.get(m.get("model") or "")
                if not key:
                    continue
                u = m.get("usage") or {}
                agg[key]["req"] += 1
                agg[key]["tok"] += (u.get("input_tokens") or 0) + (u.get("output_tokens") or 0) \
                                 + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)
    except OSError:
        continue

def fmt_tok(n):
    return f"{n/1_000_000:.1f}M" if n >= 1_000_000 else (f"{n//1000}k" if n >= 1000 else str(n))

lines = [f"  Serge quota gauge · {today} (requested-seat attribution — see quota.sh)",
         "  " + "─" * 58]
for k, label, _seats, kind, cap in BUCKETS:
    a = agg[k]
    if kind == "req":
        val = f"{a['req']} req" + (f" / ~{cap}/day" if cap else ("" if k == "paid" else " (big pool)"))
    else:
        val = f"{fmt_tok(a['tok'])} tok" + (f" / ~{fmt_tok(cap)}/day" if cap else " (~1B/month pool)")
    warn = ""
    used = a["req"] if kind == "req" else a["tok"]
    if k == "paid" and a["req"] > 0:
        warn = "  ⚠ BILLING"
    elif cap and used > cap:
        # "near cap" at 72x over is how a blown bucket reads as healthy. The
        # multiple is the number that tells you fallback is not spreading load.
        warn = f"  ⚠ OVER CAP ({used / cap:.0f}x)" if used >= cap * 2 else "  ⚠ OVER CAP"
    elif cap and used >= cap * 0.8:
        warn = "  ⚠ near cap"
    lines.append(f"  {label:28s}: {val}{warn}")
with open(os.path.join(mon, "quota-today.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")

# Print the report unless a caller asks for silence. The error messages tell
# users to "check remaining quota with ~/.serge/quota.sh", and running it
# printed NOTHING and exited 0 — a diagnostic that looks broken at the exact
# moment someone is debugging. budget-watchdog.sh already redirects to
# /dev/null; cost.sh sets SERGE_QUOTA_QUIET=1 because it cats the file itself.
if os.environ.get("SERGE_QUOTA_QUIET") != "1":
    print("\n".join(lines))

gem_rest = agg["gem3f"]["req"] + agg["gem25"]["req"]
seg = [f"brain {agg['brain']['req']}/20"]
if gem_rest:
    seg.append(f"gem+{gem_rest}")
seg.append(f"mstl {fmt_tok(agg['mistral']['tok'])}")
if agg["cereb"]["tok"]:
    seg.append(f"cereb {fmt_tok(agg['cereb']['tok'])}")
if agg["openrtr"]["req"]:
    seg.append(f"or {agg['openrtr']['req']}")
if agg["paid"]["req"]:
    seg.append(f"PAID {agg['paid']['req']}!")
# Real OpenRouter monthly spend vs the $20 cap (cached by budget-watchdog from
# the provider's own numbers — ground truth, not a token estimate). Shown only
# once there IS spend, so the all-free status quo stays visually unchanged.
try:
    sp = json.load(open(os.path.join(mon, "or-spend.json")))
    if sp.get("monthly", 0) >= 0.01:
        seg.append(f"or ${sp['monthly']:.2f}/{sp.get('monthly_cap', 20):.0f}mo")
except Exception:
    pass
with open(os.path.join(mon, "quota-line.txt"), "w") as f:
    f.write(" · ".join(seg) + "\n")
PY
