#!/usr/bin/env bash
# Serge guard-integrity — tamper-evidence for the hooks that police Serge. $0.
#
# WHY (2026-08-16): Serge was granted write access to its own engine so it can
# improve itself. It already had write access to ~/.serge. Both are deliberate —
# self-improvement is the point — but they mean the scripts that CONSTRAIN Serge
# are editable by the thing being constrained, and nothing noticed. An agent that
# can silently rewrite its own gate is not gated; it is on the honour system with
# extra steps.
#
# The obvious design — deny edits to the gates — is wrong here. It would block the
# legitimate case (every gate in this directory was written by an agent editing
# this directory) and it is trivially routed around by a subagent, a shell
# redirect, or a Write to a path built at runtime. So this does not block.
# It REMEMBERS.
#
# WHAT: a manifest of sha256 digests for every guard — the hook scripts named in
# settings.json, the stages stop-checks.sh runs, and settings.json's own `hooks`
# block. On each session start the current digests are compared to the manifest.
# Drift is not an error and is never blocked: it is REPORTED, by name, into
# NOTIFICATIONS.md (which the SessionStart loader already surfaces to the user)
# and as additionalContext so the model sees it too. Then the manifest is
# re-baselined, so each change is announced exactly once.
#
# The property this buys: a weakened gate cannot be a SILENT weakened gate. If
# Serge edits doc-reality-gate.sh at 3am, the next session opens with a line
# saying so, whether or not Serge chose to mention it.
#
# Usage:
#   guard-integrity.sh              compare + report + re-baseline  (SessionStart)
#   guard-integrity.sh --update     re-baseline silently (after intentional work)
#   guard-integrity.sh --list       print what is being watched, and exit
#
# Off-switch: SERGE_GUARD_INTEGRITY_DISABLE=1
set -uo pipefail

[ "${SERGE_GUARD_INTEGRITY_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

MODE="${1:-check}"
# Deliberately does NOT read stdin. The first version did `input="$(cat)"` for
# symmetry with the other hooks — but nothing here consumes it, and `cat` with no
# piped stdin blocks forever. Wired as SessionStart that would hang every session
# start. A hook that reads input it does not use is a deadlock waiting for a
# caller who forgets to pipe.

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}" MODE="$MODE" python3 - <<'PY'
import json, os, re, hashlib, sys, time

HOME = os.environ["SERGE_HOME"]
MODE = os.environ.get("MODE", "check")
MAN  = os.path.join(HOME, "monitor", "guard-manifest.json")
NOTE = os.path.join(HOME, "NOTIFICATIONS.md")
os.makedirs(os.path.dirname(MAN), exist_ok=True)

# ── what counts as a guard ───────────────────────────────────────────────────
watched = set()
settings_hooks_digest = None
try:
    s = json.load(open(os.path.join(HOME, "settings.json")))
    hooks = s.get("hooks") or {}
    # The wiring itself is a guard: unhooking a gate disables it without editing it.
    settings_hooks_digest = hashlib.sha256(
        json.dumps(hooks, sort_keys=True).encode()
    ).hexdigest()
    for arr in hooks.values():
        for m in arr:
            for hk in m.get("hooks", []):
                for tok in re.findall(r"[\w.-]+\.sh", hk.get("command", "")):
                    watched.add(tok)
except Exception:
    pass

# stop-checks.sh runs stages by variable, so they never appear in settings.json.
try:
    sc = open(os.path.join(HOME, "stop-checks.sh"), encoding="utf-8", errors="replace").read()
    for tok in re.findall(r"[\w.-]+\.sh", sc):
        watched.add(tok)
except Exception:
    pass

watched = sorted(t for t in watched if os.path.exists(os.path.join(HOME, t)))

if MODE == "--list":
    print(f"  {len(watched)} guard file(s) watched:")
    for t in watched:
        print("   ", t)
    print("   + settings.json[hooks] wiring digest")
    raise SystemExit

def digest(rel):
    try:
        return hashlib.sha256(open(os.path.join(HOME, rel), "rb").read()).hexdigest()
    except OSError:
        return None

current = {t: digest(t) for t in watched}
current["__settings_hooks__"] = settings_hooks_digest

prev = {}
first_run = not os.path.exists(MAN)
if not first_run:
    try:
        prev = json.load(open(MAN)).get("digests") or {}
    except Exception:
        first_run = True

def save():
    tmp = MAN + ".tmp"
    json.dump({"updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
               "digests": current}, open(tmp, "w"), indent=2)
    os.replace(tmp, MAN)

if first_run or MODE == "--update":
    save()
    if MODE == "--update":
        print(f"  guard manifest re-baselined ({len(watched)} files)")
    raise SystemExit

changed, added, removed = [], [], []
for k, v in current.items():
    if k not in prev:
        added.append(k)
    elif prev[k] != v:
        changed.append(k)
for k in prev:
    if k not in current:
        removed.append(k)

save()   # re-baseline so each change is announced exactly once

if not (changed or added or removed):
    raise SystemExit

def label(k):
    return "settings.json[hooks] wiring" if k == "__settings_hooks__" else k

lines = []
if changed: lines.append("MODIFIED: " + ", ".join(label(k) for k in sorted(changed)))
if added:   lines.append("ADDED: "    + ", ".join(label(k) for k in sorted(added)))
if removed: lines.append("REMOVED: "  + ", ".join(label(k) for k in sorted(removed)))
body = "; ".join(lines)

stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime())
try:
    with open(NOTE, "a", encoding="utf-8") as fh:
        fh.write(f"\n- **{stamp} guard-integrity** — Serge's own safety hooks changed since "
                 f"the last session. {body}. This is reported, not blocked — but if you did "
                 f"not ask for it, read the diff before trusting the next run.\n")
except Exception:
    pass

ctx = ("<system-reminder>\n"
       "GUARD INTEGRITY: the hooks that constrain you changed since the last session — "
       f"{body}. This has been recorded in NOTIFICATIONS.md for the user. If you changed "
       "them, say so plainly and say why; do not let a weakened check pass unmentioned. "
       "If you did not, treat it as a fact worth surfacing.\n"
       "</system-reminder>")
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
