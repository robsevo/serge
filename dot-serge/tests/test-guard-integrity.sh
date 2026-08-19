#!/usr/bin/env bash
# Tests for guard-integrity.sh — $0, no LLM, no network.
#
# Serge can write to ~/.serge AND (since 2026-08-16) to its own engine. That is
# deliberate — self-improvement is the point — but it means the scripts that
# CONSTRAIN Serge are editable by the thing being constrained. This hook does not
# block that; it makes it impossible for the change to be SILENT.
#
# Runs entirely against a throwaway SERGE_HOME so it can never touch the real one.
set -uo pipefail
HOOK="${SERGE_GUARD_INTEGRITY_SCRIPT:-$HOME/.serge/guard-integrity.sh}"
REAL_HOME_MAN="$HOME/.serge/monitor/guard-manifest.json"
before_real=$(sha256sum "$REAL_HOME_MAN" 2>/dev/null | cut -d' ' -f1 || echo ABSENT)

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SERGE_HOME="$T/home"
mkdir -p "$SERGE_HOME/monitor"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# a miniature ~/.serge: two gates, a stop orchestrator, and wiring
cat > "$SERGE_HOME/settings.json" <<'JSON'
{ "hooks": {
    "PreToolUse":  [ { "matcher": "Bash",  "hooks": [ { "type": "command", "command": "/h/.serge/gate-a.sh" } ] } ],
    "PostToolUse": [ { "matcher": "Edit",  "hooks": [ { "type": "command", "command": "/h/.serge/gate-b.sh" } ] } ],
    "Stop":        [ { "matcher": "*",     "hooks": [ { "type": "command", "command": "/h/.serge/stop-checks.sh" } ] } ] } }
JSON
printf '#!/bin/bash\nexit 0\n' > "$SERGE_HOME/gate-a.sh"
printf '#!/bin/bash\nexit 0\n' > "$SERGE_HOME/gate-b.sh"
printf '#!/bin/bash\nbash "$SH/stage-one.sh"\n' > "$SERGE_HOME/stop-checks.sh"
printf '#!/bin/bash\nexit 0\n' > "$SERGE_HOME/stage-one.sh"
printf '# notes\n' > "$SERGE_HOME/NOTIFICATIONS.md"

run() { bash "$HOOK" "$@"; }
noted() { grep -c "guard-integrity" "$SERGE_HOME/NOTIFICATIONS.md" 2>/dev/null || echo 0; }

echo "── discovery ──"
out=$(run --list)
printf '%s' "$out" | grep -q "gate-a.sh"     && ok "finds hooks wired in settings.json"      || bad "missed a settings.json hook"
printf '%s' "$out" | grep -q "stage-one.sh"  && ok "finds stages stop-checks.sh runs"        || bad "missed an indirect stage"
printf '%s' "$out" | grep -q "wiring digest" && ok "watches the settings.json wiring itself" || bad "wiring not watched"

echo
echo "── baseline + steady state ──"
o=$(run); [ -z "$o" ] && ok "first run seeds silently" || bad "spoke on first run"
[ -f "$SERGE_HOME/monitor/guard-manifest.json" ] && ok "manifest written" || bad "no manifest"
o=$(run); [ -z "$o" ] && ok "unchanged guards → silent" || bad "false alarm"

echo
echo "── a WEAKENED gate is reported, by name ──"
printf 'exit 0  # neutered\n' >> "$SERGE_HOME/gate-a.sh"
o=$(run)
printf '%s' "$o" | grep -q "gate-a.sh"  && ok "names the modified gate to the model" || bad "did not name it"
[ "$(noted)" -ge 1 ]                    && ok "recorded in NOTIFICATIONS.md for the user" || bad "user never told"
o=$(run); [ -z "$o" ] && ok "re-baselined: announced once, not every session" || bad "repeats forever"

echo
echo "── UNHOOKING a gate counts too (disabled without being edited) ──"
python3 - <<'PY'
import json, os
p = os.path.join(os.environ["SERGE_HOME"], "settings.json")
d = json.load(open(p))
d["hooks"]["PreToolUse"] = []          # gate-a still on disk, no longer wired
json.dump(d, open(p, "w"), indent=2)
PY
o=$(run)
printf '%s' "$o" | grep -q "wiring" && ok "caught the unhook via the wiring digest" || bad "unhook was silent"

echo
echo "── a DELETED gate is reported ──"
rm -f "$SERGE_HOME/gate-b.sh"
python3 - <<'PY'
import json, os
p = os.path.join(os.environ["SERGE_HOME"], "settings.json")
d = json.load(open(p)); d["hooks"]["PostToolUse"] = []
json.dump(d, open(p, "w"), indent=2)
PY
o=$(run)
printf '%s' "$o" | grep -qE "gate-b.sh" && ok "names the removed gate" || bad "deletion was silent"

echo
echo "── output contract + safety ──"
printf 'x\n' >> "$SERGE_HOME/stage-one.sh"
run | python3 -c '
import sys, json
d = json.load(sys.stdin); h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SessionStart", h["hookEventName"]
assert "GUARD INTEGRITY" in h["additionalContext"]
' 2>/dev/null && ok "emits valid SessionStart additionalContext" || bad "malformed hook output"

printf 'y\n' >> "$SERGE_HOME/stage-one.sh"
o=$(SERGE_GUARD_INTEGRITY_DISABLE=1 run); [ -z "$o" ] && ok "SERGE_GUARD_INTEGRITY_DISABLE=1 → inert" || bad "off-switch ignored"

o=$(run --update); printf '%s' "$o" | grep -q "re-baselined" && ok "--update re-baselines explicitly" || bad "--update broken"

# The deadlock this shipped with once: `input=$(cat)` blocks forever with no stdin,
# which as a SessionStart hook would hang every session start.
timeout 10 bash "$HOOK" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 124 ] && ok "returns without stdin (no deadlock)" || bad "HANGS waiting on stdin"

rm -rf "$SERGE_HOME/settings.json"
o=$(run 2>&1); rc=$?
[ "$rc" = 0 ] && ok "unreadable settings.json → fails open" || bad "crashed on missing settings"

after_real=$(sha256sum "$REAL_HOME_MAN" 2>/dev/null | cut -d' ' -f1 || echo ABSENT)
[ "$before_real" = "$after_real" ] && ok "suite never touched the real ~/.serge manifest" \
  || bad "the suite modified production state"

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL $pass PASS — guard integrity"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
