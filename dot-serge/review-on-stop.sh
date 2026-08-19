#!/usr/bin/env bash
# Serge auto-reviewer — openclaude Stop hook (fires once per turn, not per edit).
#
# Reads the Stop JSON on stdin, reviews the working-tree diff with the cheap
# qwen-coder model via the LiteLLM router, and surfaces a concise review.
#
# Default (cheap, non-blocking): exit 0, show the review to the USER as a hook
# systemMessage AND write it to ~/.serge/last-review.md. No model re-run, no loop.
# Set SERGE_REVIEW_ENFORCE=1 to instead feed the review back to the agent (exit 2,
# re-runs the turn once) so it fixes the issues itself — costs one extra turn.
#
# Safe no-op when: re-entry loop, no git repo, no diff, router down, no python3.
# Note: jq is NOT installed on this host — this uses python3 for JSON.
set -uo pipefail

ROUTER_URL="${SERGE_REVIEW_URL:-http://localhost:4000/v1/chat/completions}"
REVIEW_MODEL="${SERGE_REVIEW_MODEL:-qwen-coder}"
MAX_DIFF_BYTES="${SERGE_REVIEW_MAX_BYTES:-60000}"
LOG_FILE="${SERGE_REVIEW_LOG:-$HOME/.serge/last-review.md}"
ENFORCE="${SERGE_REVIEW_ENFORCE:-0}"

command -v python3 >/dev/null 2>&1 || exit 0
command -v git     >/dev/null 2>&1 || exit 0

input="$(cat)"

# Parse cwd + session from the Stop JSON (shlex.quote keeps it safe). The old
# stop_hook_active early-exit is replaced by the once-per-diff hash guard
# below — it both prevents enforce-mode re-review loops AND stops the reviewer
# re-reviewing (and re-nagging about) the same stale diff on every later stop.
eval "$(printf '%s' "$input" | python3 -c '
import sys, json, shlex
try: d = json.load(sys.stdin)
except Exception: d = {}
print("HOOK_CWD=" + shlex.quote(d.get("cwd") or ""))
print("HOOK_SID=" + shlex.quote(str(d.get("session_id") or "nosid")))
' 2>/dev/null)" || exit 0

[ -n "${HOOK_CWD:-}" ] && cd "$HOOK_CWD" 2>/dev/null || true

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0   # not a git repo -> no-op

# Tracked changes vs HEAD (staged + unstaged); fall back to plain diff if no HEAD.
diff="$(git diff --no-color HEAD 2>/dev/null)"
[ -z "$diff" ] && diff="$(git diff --no-color 2>/dev/null)"
case "$diff" in *[!$' \t\n']*) : ;; *) exit 0 ;; esac   # empty/whitespace -> no-op

# Skip review when EVERY changed file is docs/generated (a README typo or a
# regenerated lockfile isn't worth an LLM code-review call). If any code file
# changed, fall through and review. Configurable via SERGE_REVIEW_SKIP_REGEX.
files="$(git diff --name-only HEAD 2>/dev/null)"
[ -z "$files" ] && files="$(git diff --name-only 2>/dev/null)"
SKIP_RE="${SERGE_REVIEW_SKIP_REGEX:-(\.(md|markdown|txt|rst|lock)$|(^|/)(package-lock\.json|bun\.lock|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|poetry\.lock)$)}"
if [ -n "$files" ] && [ -z "$(printf '%s\n' "$files" | grep -vE "$SKIP_RE" || true)" ]; then
  exit 0
fi

# Skip trivial diffs — a couple of changed lines aren't worth an LLM review
# call (cheaper + no end-of-turn pause on tiny edits). Counts +/- content
# lines, excluding the +++/--- file headers.
MIN_CHANGED_LINES="${SERGE_REVIEW_MIN_LINES:-6}"
changed="$(printf '%s\n' "$diff" | grep -cE '^[+-]([^+-]|$)' || true)"
[ "${changed:-0}" -lt "$MIN_CHANGED_LINES" ] && exit 0

# Once-per-diff guard: review each distinct working-tree diff at most once per
# session. The diff persists until a commit, so without this every later stop
# (including chat turns) re-paid the model call and re-surfaced the same
# findings. A blocked enforce-mode re-run that didn't change the diff can't
# re-block either.
if command -v sha1sum >/dev/null 2>&1; then
  diff_hash="$(printf '%s' "$diff" | sha1sum | cut -d' ' -f1)"
  guard="${TMPDIR:-/tmp}/serge-review-$(printf '%s' "$HOOK_SID" | sha1sum | cut -c1-12).hash"
  [ "$(cat "$guard" 2>/dev/null)" = "$diff_hash" ] && exit 0
  printf '%s' "$diff_hash" > "$guard" 2>/dev/null || true
fi

diff="$(printf '%s' "$diff" | head -c "$MAX_DIFF_BYTES")"

# Ask the cheap reviewer model. Review text is captured (not printed) so that, in
# default mode, stdout carries ONLY the control JSON below.
review="$(
  SERGE_REVIEW_URL="$ROUTER_URL" SERGE_REVIEW_MODEL="$REVIEW_MODEL" \
  python3 - "$diff" <<'PY'
import os, sys, json, urllib.request
diff = sys.argv[1] if len(sys.argv) > 1 else ""
if not diff.strip(): sys.exit(0)
body = json.dumps({
  "model": os.environ["SERGE_REVIEW_MODEL"],
  # 2026-07-29: was 700, which TRUNCATED real reviews. qwen-coder (gpt-oss-120b)
  # is a reasoner: measured 484 reasoning tokens on a 2-line diff, leaving ~200
  # for the review itself and finish_reason="length" both at 700 and at 400. The
  # severity gate reads a FINAL 'BLOCKING: yes|no' line (see line ~116) — so a
  # truncated review loses its verdict, and a genuine blocking bug reads as no
  # verdict at all. Budget must cover reasoning + bullets + that last line.
  "max_tokens": 2500, "temperature": 0.1,
  "messages": [
    {"role": "system", "content": "You are a terse senior code reviewer. Given a git diff, list only concrete bugs, regressions, security issues, and risky changes as short bullets, most important first. If the diff rewrites a boolean condition (negation pushed, De Morgan flip, guards merged/split), flag it as needing a logic_check.py equiv proof unless the surrounding context shows one ran — eyeballed condition refactors are a known bug source. Flag these two classes specifically, because model-written code carries them most and both read as correct: (a) BOUNDARY slips — a comparison whose operator changed strictness, `<=` against a length, an index shifted by one, a loop that cannot advance, an empty catch; (b) COST — a linear lookup (.find/.includes/x in list) or a query or await inside a loop, an unbounded fetch, or a claimed complexity the diff does not actually achieve. For either class say to run `python3 ~/.serge/skills/complexity/algo_check.py all <file>` rather than settling it by eye. If nothing is notable, reply exactly: No issues found. Otherwise, on the FINAL line output exactly 'BLOCKING: yes' if any listed issue is a real bug, regression, security flaw, or correctness problem that should block the change, or 'BLOCKING: no' if the findings are only style, naming, or minor nits."},
    {"role": "user", "content": "Review this diff:\n\n" + diff},
  ],
}).encode()
req = urllib.request.Request(os.environ["SERGE_REVIEW_URL"], data=body,
                            headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=40) as r:
        data = json.load(r)
except Exception:
    sys.exit(0)
msg = (data.get("choices") or [{}])[0].get("message", {}).get("content", "").strip()
if msg:
    sys.stdout.write(msg)
PY
)" || exit 0

[ -z "$review" ] && exit 0

# Severity gate (the cascade): the reviewer tags a final 'BLOCKING: yes|no' line.
# Only a substantive finding (real bug/regression/security/correctness) escalates to
# the expensive cloud-brain fix + turn re-run; style/naming nits stay advisory. The
# verify stage (typecheck/test) is a STRONGER, separate gate handled upstream in
# stop-checks.sh (verify exit 2 → review skipped, turn re-runs). Missing tag → 'yes'
# so a malformed verdict fails safe toward catching a real bug in enforce mode.
blocking="$(printf '%s' "$review" | grep -oiE 'BLOCKING:[[:space:]]*(yes|no)' | tail -1 | grep -oiE 'yes|no' | tr 'A-Z' 'a-z')"
[ -z "$blocking" ] && blocking="yes"
review="$(printf '%s' "$review" | grep -viE '^[[:space:]]*BLOCKING:[[:space:]]*(yes|no)[[:space:]]*$')"

# Always persist a copy the user can read.
{ printf '# Serge auto-review — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"; printf '%s\n' "$review"; } > "$LOG_FILE" 2>/dev/null || true

# Don't nag when the reviewer found nothing.
case "$review" in "No issues found"*) exit 0 ;; esac

if [ "$ENFORCE" = "1" ] && [ "$blocking" = "yes" ]; then
  # Feed back to the agent (re-runs the turn once; guarded by stop_hook_active).
  # Reached ONLY on a substantive (blocking) finding — nits fall through to the
  # advisory note below, so the costly cloud-brain fix + re-run is reserved for
  # real bugs/regressions/security. When enforcing, also suggest fixes via the
  # cloud-brain so the re-run has a concrete path — the highest-leverage spend.
  CLOUD_URL="http://localhost:4000/v1/chat/completions"
  fix="$(
    python3 - "$diff" "$review" <<'PY'
import os, sys, json, urllib.request
diff = sys.argv[1] if len(sys.argv) > 1 else ""
review = sys.argv[2] if len(sys.argv) > 2 else ""
body = json.dumps({
  "model": "cloud-brain",
  # 2026-07-29: was 400. cloud-brain is now gemini-3.6-flash, which THINKS BY
  # DEFAULT — at ≤250 max_tokens it spends the whole budget reasoning and returns
  # content: None with finish_reason "length", i.e. an HTTP 200 that looks like
  # "no fixes needed". 400 was inside that danger zone. Measured: 254 reasoning
  # tokens on a trivial question, real content from ~600 up.
  "max_tokens": 2000, "temperature": 0.2,
  "messages": [
    {"role": "system", "content": "You are a senior engineer. Given a diff and review issues, write 1-3 concrete, minimal edit instructions to fix the issues. One line per fix. Be specific: file path, what to change."},
    {"role": "user", "content": "Diff:\n" + diff + "\n\nReview issues:\n" + review},
  ],
}).encode()
req = urllib.request.Request("http://localhost:4000/v1/chat/completions", data=body,
                            headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        data = json.load(r)
    # A thinking-by-default seat can return content: None (reasoning ate the
    # budget) — and None.strip() would raise into the bare except below, turning
    # a starved reply into a silent "no fixes needed". Fall back to the reasoning
    # text, exactly as auto-consult.sh does, and never assume the field is a str.
    m = (data.get("choices") or [{}])[0].get("message") or {}
    msg = (str(m.get("content") or "").strip()
           or str(m.get("reasoning_content") or "").strip())
    if msg: sys.stdout.write(msg)
except Exception:
    pass
PY
  )" || true
  printf '🔍 Reviewer flagged issues:\n\n%s\n' "$review" >&2
  if [ -n "$fix" ]; then
    printf '\n🧠 Cloud-brain fix plan:\n%s\n' "$fix" >&2
  fi
  exit 2
fi

# Default: surface to the USER via a hook systemMessage (no re-run, no loop).
printf '%s' "$review" | python3 -c '
import sys, json
review = sys.stdin.read().strip()
print(json.dumps({"systemMessage": "🔍 qwen-coder review of working-tree diff:\n" + review, "suppressOutput": True}))
'
exit 0
