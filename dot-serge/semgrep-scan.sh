#!/usr/bin/env bash
# PostToolUse hook — Semgrep scan on the just-edited file (local CPU, zero token cost).
#
# Fires after Edit/Write/MultiEdit. Runs Semgrep on the single edited source file.
# If Semgrep flags an issue, the finding is printed to stderr and the hook exits 2,
# which feeds it back to the model to fix before continuing. Clean scan → exit 0.
#
# PRICING: zero token cost on normal turns — Semgrep is a local static analyzer,
# NOT an LLM. The only tokens spent are the finding text fed back on the (rare)
# turns where an issue is found. Code never leaves the machine; only rule
# definitions are fetched from the registry (then cached). Usage metrics are OFF.
#
# Toggles:
#   SERGE_SEMGREP_DISABLE=1    turn the hook off entirely
#   SERGE_SEMGREP_CONFIG=...   semgrep --config value (default: p/default)
#   SERGE_SEMGREP_TIMEOUT=N    per-file semgrep timeout in seconds (default 30)
set -u

# --- fail-open guards (never block an edit on infra problems) ---
[ "${SERGE_SEMGREP_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0            # don't scan inside eval child runs

SEMGREP="$(command -v semgrep || echo "$HOME/.local/bin/semgrep")"
[ -x "$SEMGREP" ] || exit 0                       # not installed → no-op
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

# Parse the edited file path from the PostToolUse JSON — same shape serge's other
# hooks use (tool_input.file_path / .path).
FILE="$(printf '%s' "$input" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
ti = d.get("tool_input") or {}
print(ti.get("file_path") or ti.get("path") or "")
' 2>/dev/null)" || exit 0

[ -n "$FILE" ] && [ -f "$FILE" ] || exit 0

# Only scan source Semgrep has rules for; skip docs/config/lockfiles/etc.
case "$FILE" in
  *.py|*.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.go|*.rb|*.java|*.php|*.c|*.cc|*.cpp|*.h|*.hpp|*.cs|*.rs|*.kt|*.scala|*.swift|*.tf) ;;
  *) exit 0 ;;
esac

CONFIG="${SERGE_SEMGREP_CONFIG:-p/default}"
TIMEOUT="${SERGE_SEMGREP_TIMEOUT:-30}"

# Scan just this file. --metrics=off = no telemetry. --error makes semgrep exit
# non-zero when findings exist. Rules are cached after the first fetch; a network
# failure errors out with no findings → we fall through to exit 0 (fail-open).
OUT="$("$SEMGREP" scan --config "$CONFIG" --metrics=off --quiet --error \
        --timeout "$TIMEOUT" --no-rewrite-rule-ids "$FILE" 2>/dev/null)"
STATUS=$?

if [ "$STATUS" -ne 0 ] && [ -n "$OUT" ]; then
  {
    echo "⚠ Semgrep flagged potential issue(s) in $FILE — review and fix before continuing:"
    printf '%s\n' "$OUT"
  } >&2
  exit 2
fi
exit 0
