#!/usr/bin/env bash
# Serge verify-loop — openclaude Stop hook (fires once per turn, not per edit).
#
# Deterministic counterpart to review-on-stop.sh: instead of asking a model,
# it RUNS the project's own fast checks (typecheck / lint) on the changed code
# and surfaces real failures. No model call → no token cost, no latency beyond
# the checks themselves.
#
# It then scans this turn's diff for completion-criteria violations — the
# mechanically-checkable half of CONSTITUTION.trimmed.md ## execution →
# completion_criteria: merge-conflict markers, leftover debug/breakpoint
# statements, focused tests that skip the suite, and patch leftovers (.orig/.rej).
# These are treated exactly like a failed check (block by default; see below).
# The non-mechanical criteria (every requested change on disk, nothing silently
# dropped) stay prompt-enforced — a hook can't read the conversation.
#
# Default (enforce-always): exit 2 to feed failures back to the agent so it
# fixes them before finishing — re-runs the turn once, loop-guarded. Also writes
# ~/.serge/last-verify.md.
# SERGE_VERIFY_ENFORCE=0: downgrade to nudge-only — exit 0 and just surface the
# results to the USER as a hook systemMessage (the previous default behavior).
#
# Runs typecheck + lint (blocking) and the full test suite (non-blocking) by
# default. Tests can't be scoped to changed files, so a test failure only INFORMS
# — it never gates the turn (a repo with pre-existing failures isn't bricked).
# SERGE_VERIFY_TESTS=0 skips tests entirely. Detects stack from manifests:
#   package.json  → tsc --noEmit (if tsconfig) ; [tests: npm test]
#   pyproject/.py → pyright ; ruff check (if available) ; [tests: pytest]
#   Cargo.toml    → cargo check ; [tests: cargo test]
#
# Type/lint checks are scoped to files changed THIS TURN, so a pre-existing error
# in an untouched file never blocks: tsc runs whole-project (for correct module
# resolution) but only fails on diagnostics that reference changed files;
# pyright/ruff are passed the changed files directly. cargo check stays
# whole-crate (it has no clean per-file mode). Tests run in full but non-blocking.
#
# Safe no-op when: re-entry loop, no git repo, no diff, no relevant manifest,
# none of the tools installed, no python3.
set -uo pipefail

LOG_FILE="${SERGE_VERIFY_LOG:-$HOME/.serge/last-verify.md}"
ENFORCE="${SERGE_VERIFY_ENFORCE:-${SERGE_REVIEW_ENFORCE:-1}}"   # enforce-always by default; SERGE_VERIFY_ENFORCE=0 → nudge-only
RUN_TESTS="${SERGE_VERIFY_TESTS:-1}"        # full suite runs by default (non-blocking); =0 to skip
TIMEOUT="${SERGE_VERIFY_TIMEOUT:-120}"           # per blocking check (tsc/pyright/ruff)
TEST_TIMEOUT="${SERGE_VERIFY_TEST_TIMEOUT:-90}"  # per soft test suite — advisory, so capped
                                                 # tighter than blocking checks to bound end-of-
                                                 # turn latency (a slow suite times out, non-blocking)

command -v python3 >/dev/null 2>&1 || exit 0
command -v git     >/dev/null 2>&1 || exit 0

input="$(cat)"

# cwd + session from the Stop JSON (same parse as the reviewer). The old
# stop_hook_active early-exit is gone: it skipped verify on every stop after a
# nudge/block in the chain, so nudged turns finished UNVERIFIED. Loop safety
# now comes from the once-per-tree-state hash guard below instead.
eval "$(printf '%s' "$input" | python3 -c '
import sys, json, shlex
try: d = json.load(sys.stdin)
except Exception: d = {}
print("HOOK_CWD=" + shlex.quote(d.get("cwd") or ""))
print("HOOK_SID=" + shlex.quote(str(d.get("session_id") or "nosid")))
' 2>/dev/null)" || exit 0

[ -n "${HOOK_CWD:-}" ] && cd "$HOOK_CWD" 2>/dev/null || true

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Only act when something actually changed this turn.
diff="$(git diff --no-color HEAD 2>/dev/null)"
[ -z "$diff" ] && diff="$(git diff --no-color 2>/dev/null)"
case "$diff" in *[!$' \t\n']*) : ;; *) exit 0 ;; esac

# Which file types changed? (drives which checks are relevant.)
changed_files="$(git diff --name-only HEAD 2>/dev/null; git diff --name-only 2>/dev/null)"
has() { printf '%s\n' "$changed_files" | grep -qiE "$1"; }

# Files changed THIS TURN, as fixed strings for scoping checks to only what
# changed — so a pre-existing error in an untouched file can't block the turn.
# Each file is listed twice (repo-relative + absolute) so it matches tool output
# whichever form the tool prints. Also collect changed Python files (abs paths,
# existing only) so pyright/ruff can be pointed straight at them.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
changed_rel="$(printf '%s\n' "$(git diff --name-only HEAD 2>/dev/null; git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)" | sort -u | sed '/^$/d')"
CHANGED_PATTS="$(mktemp 2>/dev/null || true)"
[ -n "$CHANGED_PATTS" ] && trap 'rm -f "$CHANGED_PATTS"' EXIT
changed_py=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  p="$f"; [ -n "$ROOT" ] && p="$ROOT/$f"
  [ -n "$CHANGED_PATTS" ] && { printf '%s\n' "$f"; [ -n "$ROOT" ] && printf '%s\n' "$p"; } >>"$CHANGED_PATTS"
  case "$f" in *.py|*.pyi) [ -f "$p" ] && changed_py+=("$p") ;; esac
done <<EOF
$changed_rel
EOF

# ── Once-per-tree-state guard. The working-tree diff persists across turns
# until a commit, so before this guard EVERY stop — including pure chat turns
# that edited nothing — re-paid the full typecheck + test + reflexion latency.
# Skip when this session already verified EXACTLY this tree state (diff bytes
# + changed list + untracked file stats). Also the enforce-mode loop guard:
# a blocked re-run that didn't change the tree can't re-block. ──
if command -v sha1sum >/dev/null 2>&1; then
  state_hash="$( { printf '%s\n--\n%s\n--\n' "$diff" "$changed_rel"
    git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r u; do
      [ -f "$u" ] && stat -c '%n %s %Y' "$u" 2>/dev/null
    done; } | sha1sum | cut -d' ' -f1)"
  guard="${TMPDIR:-/tmp}/serge-verify-$(printf '%s' "$HOOK_SID" | sha1sum | cut -c1-12).hash"
  [ "$(cat "$guard" 2>/dev/null)" = "$state_hash" ] && exit 0
  printf '%s' "$state_hash" > "$guard" 2>/dev/null || true
fi

run_scoped() {  # like run(), but fails ONLY on output lines referencing changed files
  local label="$1"; shift
  local out rc filtered
  out="$(timeout "$TIMEOUT" "$@" 2>&1)"; rc=$?
  if [ -n "$CHANGED_PATTS" ] && [ -s "$CHANGED_PATTS" ]; then
    filtered="$(printf '%s\n' "$out" | grep -F -f "$CHANGED_PATTS" 2>/dev/null || true)"
  else
    filtered="$out"   # no changed-list available → behave like run() on full output
  fi
  if [ -n "$filtered" ]; then
    FAILURES="${FAILURES}### ${label} (changed files only)\n\`\`\`\n$(printf '%s' "$filtered" | head -40)\n\`\`\`\n\n"
    FAILED=1
  else
    PASSED="${PASSED}${label} ✓  "
  fi
}

run() {  # run <label> <cmd...> ; capture combined output, record pass/fail
  local label="$1"; shift
  local out rc
  out="$(timeout "$TIMEOUT" "$@" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    FAILURES="${FAILURES}### ${label} (exit ${rc})\n\`\`\`\n$(printf '%s' "$out" | tail -40)\n\`\`\`\n\n"
    FAILED=1
  else
    PASSED="${PASSED}${label} ✓  "
  fi
}

run_soft() {  # like run(), but a failure only INFORMS — it never blocks the turn.
  local label="$1"; shift            # used for full-suite tests, which can't be
  local out rc                       # scoped to changed files, so a pre-existing
  out="$(timeout "$TEST_TIMEOUT" "$@" 2>&1)"; rc=$?   # failure must not brick every turn.
  if [ "$rc" -ne 0 ]; then
    SOFT_FAILURES="${SOFT_FAILURES}### ${label} (exit ${rc}, non-blocking)\n\`\`\`\n$(printf '%s' "$out" | tail -40)\n\`\`\`\n\n"
  else
    PASSED="${PASSED}${label} ✓  "
  fi
}

FAILURES=""; PASSED=""; SOFT_FAILURES=""; FAILED=0

# ── TypeScript / JavaScript ───────────────────────────────────────────────
if { has '\.(ts|tsx|js|jsx)$'; } && [ -f package.json ]; then
  if [ -f tsconfig.json ] && command -v npx >/dev/null 2>&1; then
    # Whole-project compile (correct module resolution), but only FAIL on errors
    # in files changed this turn — pre-existing errors elsewhere don't block.
    run_scoped "tsc --noEmit" npx --no-install tsc --noEmit
  fi
  if [ "$RUN_TESTS" = "1" ] && command -v npm >/dev/null 2>&1; then
    run_soft "npm test" npm test --silent
  fi
fi

# ── Python ────────────────────────────────────────────────────────────────
if has '\.pyi?$'; then
  # pyright/ruff take file args natively, so point them at just the changed
  # files; fall back to whole-project only if we couldn't resolve the list.
  if command -v pyright >/dev/null 2>&1; then
    if [ ${#changed_py[@]} -gt 0 ]; then run "pyright" pyright "${changed_py[@]}"
    else run "pyright" pyright; fi
  fi
  if command -v ruff >/dev/null 2>&1; then
    if [ ${#changed_py[@]} -gt 0 ]; then run "ruff check" ruff check "${changed_py[@]}"
    else run "ruff check" ruff check .; fi
  fi
  if [ "$RUN_TESTS" = "1" ] && command -v pytest >/dev/null 2>&1; then
    run_soft "pytest" pytest -q
  fi
fi

# ── Rust ──────────────────────────────────────────────────────────────────
if has '\.rs$' && [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
  run "cargo check" cargo check --quiet
  if [ "$RUN_TESTS" = "1" ]; then run_soft "cargo test" cargo test --quiet; fi
fi

# ── Completion criteria (deterministic; scans this turn's diff) ─────────────
# Folds into FAILURES/FAILED so it surfaces by default and blocks under
# SERGE_REVIEW_ENFORCE, identical to a typecheck failure. Scans ADDED lines
# only (the '+' side of the diff, excluding the '+++' file headers). Patterns
# are chosen to be high-signal / near-zero false-positive on real code & prose.
added="$(printf '%s\n' "$diff" | grep -E '^\+' | grep -vE '^\+\+\+' || true)"

comp_fail() {  # comp_fail <label> <matching-lines>
  FAILURES="${FAILURES}### completion: ${1}\n\`\`\`\n$(printf '%s' "$2" | sed 's/^+//' | head -20)\n\`\`\`\n\n"
  FAILED=1
}

# A) Merge-conflict markers. 7-char arrow runs effectively never occur in real
#    content; '=======' is intentionally excluded (collides with Markdown H1).
hits="$(printf '%s\n' "$added" | grep -nE '^\+(<{7}|>{7})' || true)"
[ -n "$hits" ] && comp_fail "merge-conflict markers left in the diff" "$hits"

# B) Debug / breakpoint statements left in code (console.log excluded — too
#    often legitimate). Covers JS/TS, Python, Rust, Ruby.
hits="$(printf '%s\n' "$added" | grep -nE '\b(debugger|pdb\.set_trace|breakpoint[[:space:]]*\(|import[[:space:]]+pdb|binding\.pry|byebug)\b|dbg!\(' || true)"
[ -n "$hits" ] && comp_fail "debug/breakpoint statements left in code" "$hits"

# C) Focused tests that silently skip the rest of the suite. '.only(' and
#    'fdescribe(' are test-runner-specific; bare 'fit(' is excluded (collides
#    with sklearn/scipy .fit()).
hits="$(printf '%s\n' "$added" | grep -nE '\.only\(|\bfdescribe\(|\bfcontext\(' || true)"
[ -n "$hits" ] && comp_fail "focused tests (.only / fdescribe) left in — would skip the rest of the suite" "$hits"

# D) Patch / merge leftover files in the tree (tracked changes + new untracked).
leftovers="$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | grep -iE '\.(orig|rej)$' | sort -u || true)"
[ -n "$leftovers" ] && comp_fail "patch/merge leftover files present (.orig / .rej)" "$leftovers"

# Nothing ran at all (no relevant tool/manifest) → silent no-op.
[ -z "$PASSED" ] && [ "$FAILED" = "0" ] && [ -z "$SOFT_FAILURES" ] && exit 0

# Persist a copy.
{
  printf '# Serge verify — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  [ -n "$PASSED" ] && printf 'Passed: %s\n\n' "$PASSED"
  [ "$FAILED" = "1" ] && printf '%b' "$FAILURES"
  [ -n "$SOFT_FAILURES" ] && { printf '## non-blocking (full-suite tests)\n\n'; printf '%b' "$SOFT_FAILURES"; }
} > "$LOG_FILE" 2>/dev/null || true

# All clear (no hard failures, no soft failures) → don't nag.
[ "$FAILED" = "0" ] && [ -z "$SOFT_FAILURES" ] && exit 0

# Reflexion memory: record this EXTERNAL-ground-truth failure (hard or soft) so the
# reflection loop / SessionStart (reflexion-load.sh) can surface RECURRING mistakes.
# Runs in enforce OR nudge mode (the failure is real either way). Non-blocking,
# fail-open — never affects the verdict below.
REFLEXION="${SERGE_REFLEXION_SCRIPT:-$HOME/.serge/reflexion-log.sh}"
if [ "${SERGE_REFLEXION_DISABLE:-0}" != "1" ] && { [ -x "$REFLEXION" ] || [ -f "$REFLEXION" ]; }; then
  { [ "$FAILED" = "1" ] && printf '%b' "$FAILURES"; [ -n "$SOFT_FAILURES" ] && printf '%b' "$SOFT_FAILURES"; } \
    | bash "$REFLEXION" "${HOOK_CWD:-$PWD}" "$ENFORCE" "$changed_rel" >/dev/null 2>&1 || true
fi

# Whack-a-mole tripwire: reflexion-log.sh just appended this failure with a
# path-independent signature + running count. If the SAME signature recurred
# within a few hours, the session is patching symptoms in a circle — surface
# that loudly so the constitution's Whack-a-Mole rule actually triggers.
WHACK=""
if [ "${SERGE_REFLEXION_DISABLE:-0}" != "1" ]; then
  WHACK="$(python3 - "${SERGE_REFLEXION_LOG:-$HOME/.serge/reflexion-log.jsonl}" <<'PY' 2>/dev/null
import sys, json, datetime
try:
    lines = [l for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
    last = json.loads(lines[-1])
except Exception:
    sys.exit(0)
n = int(last.get("count") or 0)
if n < 2:
    sys.exit(0)
# Only nag when the recurrence is recent (same working bout, not last week).
try:
    sig = last.get("sig")
    prev = next((json.loads(l) for l in lines[-2::-1]
                 if json.loads(l).get("sig") == sig), None)
    if prev:
        dt = (datetime.datetime.fromisoformat(last["ts"])
              - datetime.datetime.fromisoformat(prev["ts"])).total_seconds()
        if dt > 3 * 3600:
            sys.exit(0)
except Exception:
    pass
cats = ", ".join(last.get("categories") or []) or "same checks"
print(f"WHACK-A-MOLE tripwire: this exact failure signature ({cats}) has now "
      f"appeared {n}x. Stop patching the symptom — re-read the failing output, "
      "hold two competing root-cause hypotheses, and fix the CAUSE "
      "(constitution: debugging / root_cause_verification).")
PY
)"
fi

# HARD failures (typecheck / lint / completion) gate the turn under enforce.
# SOFT failures (tests) only inform — they ride along but never cause exit 2,
# so a repo with pre-existing test failures isn't bricked on every turn.
if [ "$FAILED" = "1" ] && [ "$ENFORCE" = "1" ]; then
  printf '🧪 Verify failed — fix these before finishing:\n\n%b' "$FAILURES" >&2
  [ -n "$WHACK" ] && printf '\n⚠️ %s\n' "$WHACK" >&2
  [ -n "$SOFT_FAILURES" ] && printf '\n— also failing (non-blocking; fix only if your change caused it):\n\n%b' "$SOFT_FAILURES" >&2
  exit 2
fi

# Otherwise (no hard failures, or not enforcing): surface to the USER, no block.
{ [ "$FAILED" = "1" ] && printf '%b' "$FAILURES"; [ -n "$SOFT_FAILURES" ] && printf '%b' "$SOFT_FAILURES"; [ -n "$WHACK" ] && printf '\n⚠️ %s\n' "$WHACK"; } | python3 -c '
import sys, json
fails = sys.stdin.read().strip()
print(json.dumps({"systemMessage": "🧪 Verify:\n" + fails, "suppressOutput": True}))
'
exit 0
