#!/usr/bin/env bash
# Measure how well subagents actually FOLLOW the swarm doctrine.
#
# ⚠ THIS ONE SPENDS REAL MODEL CALLS. Every other file in this directory is $0
# and offline; this is named measure-* rather than test-* so it is never swept
# into a run-everything loop. Default cost: 2 runs × 3 agents = 6 subagent calls
# on free seats.
#
# WHY IT EXISTS: the doctrine is a prompt, and a prompt's effect is an empirical
# question, not a design one. Editing ~/.serge/swarm-doctrine.md and reasoning
# about whether it reads better is how prompt files rot — they grow, each
# addition looks sensible, and nobody notices the whole thing stopped landing.
#
# What it found the first time it was run (2026-08-15, free seat, n=6 per arm):
#
#   doctrine 456 words, return shape at the END   1/6 agents complied (16%)
#   doctrine 110 words, return shape at the TOP   5/6 agents complied (83%)
#
# So the binding constraint was not what the rules said but how much the agent
# was holding at once — and position mattered as much as length: the one thing
# that had to survive to the end of a run was the last thing in the document.
# Every sentence added to the doctrine costs compliance on all the others.
#
# THE SIGNAL: the FOUND/UNKNOWN/CONFIDENCE return shape. Nothing else in the
# stack asks for it, so if it appears, the doctrine both reached that agent and
# was obeyed. Citations are tracked as a second, softer signal.
#
# Usage:
#   measure-swarm-doctrine.sh            2 runs (6 agents)
#   measure-swarm-doctrine.sh 4          4 runs (12 agents) — tighter, costs more
#   measure-swarm-doctrine.sh 2 --keep   keep the fixture for inspection
#
# It leaves your swarm config exactly as it found it, including if you Ctrl-C.
set -uo pipefail

RUNS="${1:-2}"
KEEP="${2:-}"
SERGE_BIN="${SERGE_BIN:-serge}"
CONF="${SERGE_SWARM_CONF:-$HOME/.serge/swarm.json}"
SWARM="${SERGE_SWARM_SH:-$HOME/.serge/swarm.sh}"

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
command -v "$SERGE_BIN" >/dev/null 2>&1 || { echo "serge not on PATH" >&2; exit 1; }
[ -f "$CONF" ] || { echo "No swarm config at $CONF — run $SWARM once first." >&2; exit 1; }

case "$RUNS" in ''|*[!0-9]*) echo "Usage: measure-swarm-doctrine.sh [runs] [--keep]" >&2; exit 1 ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/swarm-measure-XXXXXX")"
CONF_BAK="$(mktemp "${TMPDIR:-/tmp}/swarm-conf-XXXXXX.json")"
cp -p "$CONF" "$CONF_BAK"

restore() {
  # Always put the user's config back. This test turns swarm mode ON to measure
  # it; leaving it on afterwards would silently change every later session.
  cp -p "$CONF_BAK" "$CONF" 2>/dev/null || true
  rm -f "$CONF_BAK" 2>/dev/null || true
  if [ "$KEEP" = "--keep" ]; then
    echo "  fixture kept: $WORK"
  else
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap restore EXIT INT TERM

# ── fixture: three independent areas, so a 3-way split is the natural shape ──
mkdir -p "$WORK"/{auth,billing,api}
cat > "$WORK/auth/session.js" <<'EOF'
const TTL_SECONDS = 3600;
function createSession(user) {
  return { user, expires: Date.now() + TTL_SECONDS * 1000 };
}
function isExpired(s) { return Date.now() > s.expires; }
module.exports = { createSession, isExpired, TTL_SECONDS };
EOF
cat > "$WORK/billing/charge.js" <<'EOF'
const MAX_CENTS = 50000;
async function charge(customer, cents) {
  if (cents > MAX_CENTS) throw new Error('over limit');
  while (true) {                      // unbounded retry loop
    try { return await gateway.post(customer, cents); }
    catch (e) { continue; }
  }
}
module.exports = { charge, MAX_CENTS };
EOF
cat > "$WORK/api/routes.js" <<'EOF'
const { createSession } = require('../auth/session');
const { charge } = require('../billing/charge');
function register(app) {
  app.post('/login', (req, res) => res.json(createSession(req.body.user)));
  app.post('/pay', (req, res) => charge(req.body.customer, req.body.cents));
}
module.exports = { register };
EOF

DOC="$(python3 -c "
import json,os,re,sys
c=json.load(open('$CONF'))
p=os.path.expanduser(str(c.get('doctrine_file') or ''))
try: print(len(re.sub(r'<!--.*?-->','',open(p).read(),flags=re.S).split()))
except Exception: print('?')")"
MEAS="$(python3 -c "
import json;c=json.load(open('$CONF'));print(','.join(c.get('measures') or []) or '(none)')")"

echo "Swarm doctrine adherence — $RUNS run(s) × 3 agents"
echo "  doctrine : $DOC words"
echo "  measures : $MEAS"
echo "  fixture  : $WORK"
echo "  (spending $((RUNS * 3)) subagent calls on free seats)"
echo

bash "$SWARM" on >/dev/null 2>&1
bash "$SWARM" agents 3 >/dev/null 2>&1

for i in $(seq 1 "$RUNS"); do
  printf '  run %d/%d … ' "$i" "$RUNS"
  ( cd "$WORK" && timeout 420 "$SERGE_BIN" -p \
      "Fan out to 3 general-purpose agents in parallel, one per file: auth/session.js, billing/charge.js, api/routes.js. Each should audit its file for correctness hazards." \
      >/dev/null 2>&1 )
  echo "done"
  sleep 2
done
echo

# The project transcript dir is keyed off the sanitized cwd, same rule memdir
# uses. Derive it rather than guessing, so a changed fixture path cannot make
# this silently measure zero agents and report success.
TXDIR="$(python3 -c "
import re,os
root=os.path.realpath('$WORK')
print(os.path.join(os.path.expanduser('${CLAUDE_CONFIG_DIR:-$HOME/.serge}'),'projects',re.sub(r'[^a-zA-Z0-9]','-',root)))")"

python3 - "$TXDIR" <<'PY'
import glob, json, os, re, sys

txdir = sys.argv[1]
files = glob.glob(os.path.join(txdir, "*.jsonl"))
agents = []
for p in files:
    rows = []
    for line in open(p, encoding="utf-8", errors="ignore"):
        line = line.strip()
        if not line:
            continue
        try: rows.append(json.loads(line))
        except Exception: pass
    ids = {}
    for e in rows:
        c = (e.get("message") or {}).get("content")
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Agent":
                    ids[b["id"]] = str(b.get("input", {}).get("description") or "?")[:34]
    for e in rows:
        c = (e.get("message") or {}).get("content")
        if isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id") in ids:
                    t = b.get("content")
                    if isinstance(t, list):
                        t = " ".join(x.get("text", "") for x in t if isinstance(x, dict))
                    t = str(t)
                    agents.append({
                        "desc": ids[b["tool_use_id"]],
                        "markers": sum(k in t for k in ("FOUND", "UNKNOWN", "CONFIDENCE")),
                        "cites": len(re.findall(r"[\w./-]+\.(?:js|ts|py|sh):\d+", t)),
                    })

n = len(agents)
if not n:
    print(f"  NO AGENT RESULTS in {txdir}")
    print("  Nothing was measured — do not read this as a pass. Check that the")
    print("  run spawned agents at all (swarm mode on? serge reachable?).")
    sys.exit(2)

full = sum(1 for a in agents if a["markers"] == 3)
cited = sum(1 for a in agents if a["cites"] > 0)
print(f"  agents sampled     : {n}")
print(f"  full return shape  : {full}/{n}  ({100*full//n}%)")
print(f"  cited file:line    : {cited}/{n}  ({100*cited//n}%)")
print(f"  avg markers (of 3) : {sum(a['markers'] for a in agents)/n:.1f}")
print()
for a in agents:
    print(f"    {'OK ' if a['markers']==3 else '   '} {a['desc']:<36} markers={a['markers']} cites={a['cites']}")
print()
print("  Reference (2026-08-15, free seat, n=6): 456-word doctrine 16% · 110-word 83%.")
print("  A drop toward ~16% means the doctrine has grown past what the seat holds.")
PY
