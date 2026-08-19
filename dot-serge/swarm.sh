#!/usr/bin/env bash
# Swarm mode control ($0, no LLM — reads/writes ~/.serge/swarm.json).
#
# WHY A STATE FILE AND NOT AN ENV VAR: hooks run as separate processes and
# serge.env is read once at launch, so an env toggle cannot be flipped
# mid-session — you would have to restart to change your mind. Serge already
# uses state files for exactly this (monitor/.uncap-day, .budget-capped), and
# this follows that pattern: flip the file, next hook invocation sees it.
#
# WHY NOT A PERMISSION MODE (shift+tab): the cycle is a hardcoded switch over
# the PermissionMode union, which 93 files consume and 14 switch on, and a new
# member would have to answer "what may tools do in this mode?" — a question
# doctrine has no opinion about. Permission modes also govern the MAIN session,
# while this is aimed at subagents. Wrong shelf.
#
# Distinct from /hive: hive is an EFFORT dial (when to escalate to the scarce
# architect seat). Swarm is about FAN-OUT — how many agents run in parallel and
# what rules they each carry. They compose; neither implies the other.
#
# Usage:
#   swarm.sh                 show status
#   swarm.sh toggle          flip on/off (what `/swarm` runs)
#   swarm.sh on | off
#   swarm.sh agents <n>      max parallel subagents
#   swarm.sh only <regex>    restrict doctrine to agent types (or '*' for all)
#   swarm.sh lead on|off     whether the lead is briefed too
#   swarm.sh doctrine        print the doctrine file path + contents
#   swarm.sh measures        list available measures and which are on
#   swarm.sh measure <name>  toggle one on/off (persistence, etc.)
#   swarm.sh --json          machine-readable state (for the statusline)
set -uo pipefail

CONF="${SERGE_SWARM_CONF:-$HOME/.serge/swarm.json}"
command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 0; }

[ -f "$CONF" ] || printf '{"enabled": false, "max_agents": 3, "agents": "*", "doctrine_file": "~/.serge/swarm-doctrine.md", "brief_lead": true}\n' > "$CONF"

ACTION="${1:-status}"; VALUE="${2:-}"

CONF="$CONF" ACTION="$ACTION" VALUE="$VALUE" python3 <<'PY'
import json, os, re, sys

conf = os.environ["CONF"]
action = os.environ["ACTION"].lstrip("-").lower()
value = os.environ["VALUE"]

def load():
    try:
        with open(conf) as f:
            return json.load(f)
    except Exception:
        return {}

def save(d):
    # Preserve the _comment keys — they are the file's documentation and a
    # rewrite that drops them turns a self-explaining config into a mystery.
    try:
        with open(conf, "w") as f:
            json.dump(d, f, indent=2)
            f.write("\n")
        return True
    except Exception as e:
        print(f"Could not write {conf}: {e}", file=sys.stderr)
        return False

d = load()
enabled = bool(d.get("enabled"))
mx = d.get("max_agents", 3)
who = d.get("agents", "*")
lead = bool(d.get("brief_lead", True))
measures = list(d.get("measures") or [])
MEASURE_DIR = os.path.expanduser(
    str(d.get("measures_dir") or "~/.serge/swarm-measures"))

def available_measures():
    try:
        return sorted(
            f[:-3] for f in os.listdir(MEASURE_DIR) if f.endswith(".md"))
    except Exception:
        return []
doc = os.path.expanduser(str(d.get("doctrine_file") or "~/.serge/swarm-doctrine.md"))

def status(prefix=""):
    state = "ON" if d.get("enabled") else "off"
    print(f"{prefix}Swarm mode: {state}")
    if d.get("enabled"):
        print(f"  max parallel agents : {d.get('max_agents', 3)}")
        print(f"  doctrine applies to : {d.get('agents', '*')}")
        print(f"  lead briefed        : {'yes' if d.get('brief_lead', True) else 'no'}")
        ms = d.get("measures") or []
        print(f"  measures on         : {', '.join(ms) if ms else '(none)'}")
        dp = os.path.expanduser(str(d.get("doctrine_file") or ""))
        if os.path.exists(dp):
            # Count what is ACTUALLY injected, not what is on disk (fixed
            # 2026-08-15). The old line counted the raw doctrine file only, so it
            # was wrong twice over: it counted the HTML comment block that
            # swarm-doctrine.sh strips (+117 words here) and it ignored every
            # enabled measure (-200). The two errors partly cancelled, which is
            # why "~227 words" looked plausible against a real 337 — 48% low.
            # Worse than the offset: toggling a measure did not move the number
            # at all, so the one figure a user reads before paying it was blind
            # to the setting most likely to change it.
            # Mirror swarm-doctrine.sh's assembly exactly; if that changes, this
            # must change with it.
            def _body(path):
                try:
                    with open(path, encoding="utf-8", errors="ignore") as fh:
                        return re.sub(r"<!--.*?-->", "", fh.read(), flags=re.S).strip()
                except Exception:
                    return ""
            words = len(_body(dp).split())
            words += 27  # the "SWARM DOCTRINE — ..." preamble the hook prepends
            missing = []
            for name in (d.get("measures") or []):
                safe = os.path.basename(str(name))
                mp = os.path.join(MEASURE_DIR, safe + ".md")
                body = _body(mp)
                if body:
                    words += len(body.split()) + 3  # + the "## name" heading
                else:
                    missing.append(safe)
            n = d.get("max_agents", 3)
            print(f"  doctrine            : {dp}")
            print(f"  cost                : ~{words} words × up to {n} agents "
                  f"(doctrine + {len(d.get('measures') or []) - len(missing)} measure(s))")
            if missing:
                # An enabled measure whose file is gone injects nothing. Silence
                # here would read as "it is applied" — say so instead.
                print(f"  ⚠ measures enabled but MISSING (inject nothing): {', '.join(missing)}")
        else:
            print(f"  doctrine            : MISSING ({dp}) — nothing will be injected")
    else:
        print("  (costs nothing while off — no hook injects anything)")

if action in ("status", ""):
    status()

elif action == "json":
    print(json.dumps({
        "enabled": enabled, "max_agents": mx, "agents": who,
        "brief_lead": lead, "doctrine_file": doc,
    }))

elif action in ("toggle", "t"):
    d["enabled"] = not enabled
    if save(d):
        status()

elif action in ("on", "enable"):
    d["enabled"] = True
    if save(d):
        status()

elif action in ("off", "disable"):
    d["enabled"] = False
    if save(d):
        status()

elif action in ("agents", "n", "max"):
    try:
        n = int(value)
    except Exception:
        print("Usage: swarm.sh agents <number>", file=sys.stderr); sys.exit(1)
    if n < 1 or n > 20:
        # Not arbitrary: free seats are rpm-limited and a wide fan-out is what
        # trips the shared Mistral budget. Above ~8 the agents queue behind each
        # other and the parallelism is imaginary.
        print("Pick 1-20. Above ~8 they queue on free seats and it stops being parallel.", file=sys.stderr)
        sys.exit(1)
    d["max_agents"] = n
    if save(d):
        status()

elif action == "only":
    d["agents"] = value if value else "*"
    if save(d):
        print(f"Doctrine now applies to: {d['agents']}")
        if value and value != "*":
            print("(agent types are matched by the SubagentStart matcher — a regex over agent_type)")

elif action == "lead":
    d["brief_lead"] = value.lower() not in ("off", "false", "0", "no")
    if save(d):
        status()

elif action in ("measures", "measure-list"):
    avail = available_measures()
    if not avail:
        print(f"No measures in {MEASURE_DIR}.")
        print("A measure is just a .md file there — drop one in and it appears here.")
    else:
        print(f"Measures in {MEASURE_DIR}:")
        for m in avail:
            mark = "on " if m in measures else "   "
            first = ""
            try:
                for line in open(os.path.join(MEASURE_DIR, m + ".md"), encoding="utf-8", errors="ignore"):
                    line = line.strip()
                    if line and not line.startswith(("#", "<!--")):
                        first = line[:64]; break
            except Exception:
                pass
            print(f"  [{mark}] {m:<14} {first}")
        print()
        print("Toggle one: swarm.sh measure <name>")

elif action == "measure":
    if not value:
        print("Usage: swarm.sh measure <name>", file=sys.stderr); sys.exit(1)
    avail = available_measures()
    if value not in avail:
        print(f"No measure '{value}'. Available: {', '.join(avail) or '(none)'}", file=sys.stderr)
        print(f"To add one: write {os.path.join(MEASURE_DIR, value + '.md')}", file=sys.stderr)
        sys.exit(1)
    if value in measures:
        measures.remove(value); verb = "off"
    else:
        measures.append(value); verb = "on"
    d["measures"] = measures
    if save(d):
        print(f"Measure '{value}' is now {verb}.")
        print(f"  measures on: {', '.join(measures) if measures else '(none)'}")

elif action == "doctrine":
    print(f"DOCTRINE FILE: {doc}")
    print("---")
    try:
        print(open(doc, encoding="utf-8", errors="ignore").read())
    except Exception:
        print("(missing — create it, or `swarm.sh off`)")

else:
    print(f"Unknown action '{action}'. Try: status | toggle | on | off | agents <n> | only <regex> | lead on|off | doctrine", file=sys.stderr)
    sys.exit(1)
PY
exit 0
