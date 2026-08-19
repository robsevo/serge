#!/usr/bin/env bash
# Serge Stop orchestrator — runs the deterministic verifier first, then the LLM
# reviewer ONLY if the verifier didn't hard-block the turn.
#
# Why this exists: the harness runs sibling Stop hooks in PARALLEL (verified in
# utils/hooks.ts — matchingHooks.map(async …) → Promise.all), so verify and review
# would start at the same instant and review couldn't know verify's result for the
# turn. Chaining them in ONE process makes the order deterministic: when verify
# hard-fails (exit 2), the diff is going to change, so the (token-spending) review
# is skipped entirely — saving a qwen-coder call and, in enforce mode, the
# cloud-brain fix call. The two underlying scripts are unchanged building blocks.
#
# Trade-off: verify and review now run in sequence, not parallel, so a PASSING turn
# can take longer end-to-end; but a HARD-FAILING turn is faster (review skipped).
# That favors cost over latency, matching Serge's "keep it cheap" priority.
#
# Timeout budget (the harness ceiling for THIS hook is set in settings.json and must
# cover the sum of the inner per-check timeouts, or a check gets killed mid-run —
# the same bug class as the old review-on-stop cap). Realistic single-language,
# enforce-mode worst case: one blocking check (tsc/pyright ≤120s) + soft tests
# (≤90s, SERGE_VERIFY_TEST_TIMEOUT) + review (qwen ≤40s + cloud fix ≤60s = 100s)
# ≈ 310s; +~60s for process spawn / curl / git diffs → ceiling 480s. Typical turns
# finish in well under a minute; 480 is a backstop, not the expected wait. (Rare
# multi-language turns editing .ts + .py + .rs at once can exceed it; acceptable.)
#
# Exit/stdout contract matches the child hooks: exit 2 (+stderr) blocks and re-runs
# the turn; a single {"systemMessage":…} JSON on stdout surfaces a non-blocking note.
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"
PERSIST="${SERGE_PERSIST_SCRIPT:-$SH/continue-on-unfinished.sh}"
VERIFY="${SERGE_VERIFY_SCRIPT:-$SH/verify-on-stop.sh}"
REVIEW="${SERGE_REVIEW_SCRIPT:-$SH/review-on-stop.sh}"

input="$(cat)"

# ── Esc means STOP. Guard the WHOLE pipeline, not one stage ──────────────────
# When the user interrupts a turn, every stage below is reasoning about work
# they just cancelled, and two of them can restart it: verify exits 2 on a
# failing typecheck and exit 2 RE-ENTERS the turn, and review does the same
# under SERGE_REVIEW_ENFORCE=1 (which --auto/--yolo force on). Mid-edit code is
# usually broken code, so an Esc during an edit is exactly when verify fails —
# the user presses Esc, serge resumes, they press Esc again. That is the "it
# retries 5 times when I try to stop it" loop.
#
# continue-on-unfinished.sh (Stage 0) already refuses to nudge an interrupted
# turn, but it guards only ITSELF. Same lesson as the D6 background-tasks
# guard: the check has to precede every stage, not the first one.
#
# Review also costs a model call, so running it on an abandoned turn spends
# scarce free quota for output nobody will read.
#
# Reads `last_assistant_message` in-band rather than the transcript: the
# transcript may not be flushed when Stop fires (the stall-nudge race).
# Matches both '[Request interrupted by user]' and '…by user for tool use]'.
# Escape hatch: SERGE_STOP_IGNORE_INTERRUPT=1 runs the checks anyway.
if [ "${SERGE_STOP_IGNORE_INTERRUPT:-0}" != "1" ]; then
  if printf '%s' "$input" | python3 -c '
import json, re, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)                      # unparseable → do not claim an interrupt
msg = str(d.get("last_assistant_message") or "")
sys.exit(0 if re.match(r"^\s*\[Request interrupted by user", msg, re.I) else 1)
' 2>/dev/null; then
    exit 0
  fi
fi

vout="$(mktemp)"; verr="$(mktemp)"; rout="$(mktemp)"; rerr="$(mktemp)"; gout="$(mktemp)"; gerr="$(mktemp)"
trap 'rm -f "$vout" "$verr" "$rout" "$rerr" "$gout" "$gerr"' EXIT

# ── Stage 0: mechanical persistence nudges (stall / false-done) — python-only,
#    milliseconds, no model call. Runs FIRST because a nudge means the turn is
#    about to CONTINUE: the harness waits for this whole hook before acting, so
#    running verify (typecheck+tests, up to ~3 min) and review (model call)
#    before delivering the nudge just made every "unfinished task" iteration
#    crawl. On a nudge, short-circuit — the heavy checks run on the REAL final
#    stop of the chain (their diff-hash guards prevent duplicate work there).
#    Was a sibling Stop hook until 2026-07-17; folded in for exactly this. ──
if [ -x "$PERSIST" ] || [ -f "$PERSIST" ]; then
  pout="$(printf '%s' "$input" | bash "$PERSIST" 2>/dev/null)" || true
  case "$pout" in
    *'"decision"'*'"block"'*)
      printf '%s\n' "$pout"
      exit 0
      ;;
  esac
fi

# ── Stage 0.5: fabricated-link check ($0, no model call). Sits here for the same
#    reason Stage 0 does — a block means the turn CONTINUES, so it must not wait
#    on verify's typecheck/tests first. It is cheaper than Stage 0 on the common
#    path (no URLs in the final message ⇒ one regex, no network) and only reaches
#    the network for links serge produced that appear in NO session input.
#    Placed AFTER Stage 0 so a persistence nudge still short-circuits first: an
#    unfinished turn is going to be rewritten anyway, links included. ──
URLCHK="${SERGE_URL_VERIFY_SCRIPT:-$SH/url-verify-on-stop.sh}"
if [ -x "$URLCHK" ] || [ -f "$URLCHK" ]; then
  uout="$(printf '%s' "$input" | bash "$URLCHK" 2>/dev/null)" || true
  case "$uout" in
    *'"decision"'*'"block"'*)
      printf '%s\n' "$uout"
      exit 0
      ;;
  esac
fi

# ── Stage 0.6: claims gate ($0 unless the turn made claims). Independent
#    verification of a <claims> block: the file is re-hashed HERE, the command is
#    looked up in this turn's own record, the URL is re-fetched. Every other stage
#    reasons about PROSE; this one is the only check that compares an assertion to
#    the thing itself, so a model cannot predict its way past a sha256 it never
#    computed. Costs one regex on turns with no claims block, which is most of
#    them. Placed after Stage 0/0.5 for their reason: a turn already being
#    rewritten will restate its claims anyway. ──
CLAIMS="${SERGE_CLAIMS_SCRIPT:-$SH/claims-gate.sh}"
if [ -x "$CLAIMS" ] || [ -f "$CLAIMS" ]; then
  cout="$(printf '%s' "$input" | bash "$CLAIMS" 2>/dev/null)" || true
  case "$cout" in
    *'"decision"'*'"block"'*)
      printf '%s\n' "$cout"
      exit 0
      ;;
  esac
fi

# ── Stage 1: deterministic verify (typecheck/lint/completion + soft tests) ──
if [ -x "$VERIFY" ] || [ -f "$VERIFY" ]; then
  printf '%s' "$input" | bash "$VERIFY" >"$vout" 2>"$verr"; vrc=$?
else
  vrc=0
fi

if [ "$vrc" -eq 2 ]; then
  # Verify is blocking the turn. Skip the review entirely (the diff will change).
  cat "$verr" >&2
  [ -s "$vout" ] && cat "$vout"          # normally empty when verify exits 2
  exit 2
fi

# ── Stage 2: LLM review — only reached when verify did NOT hard-block ──
if [ -x "$REVIEW" ] || [ -f "$REVIEW" ]; then
  printf '%s' "$input" | bash "$REVIEW" >"$rout" 2>"$rerr"; rrc=$?
else
  rrc=0
fi

if [ "$rrc" -eq 2 ]; then
  # Reviewer is blocking (enforce mode + issues). Forward its feedback. Verify's
  # non-blocking note (if any) is already persisted to ~/.serge/last-verify.md.
  cat "$rerr" >&2
  exit 2
fi

# ── Stage 3: constitution behavior gate. Cheap hash check; the eval suite runs
#    ONLY when a behavior-defining file changed since the last gate, so normal
#    turns add ~milliseconds. On enforce-mode regression it blocks (exit 2). ──
GATE="${SERGE_GATE_STOP_SCRIPT:-$SH/gate-on-stop.sh}"
if [ -x "$GATE" ] || [ -f "$GATE" ]; then
  printf '%s' "$input" | bash "$GATE" >"$gout" 2>"$gerr"; grc=$?
else
  grc=0
fi

if [ "$grc" -eq 2 ]; then
  # Gate is blocking (enforce mode + genuine post-edit regression). Forward it.
  cat "$gerr" >&2
  exit 2
fi

# ── Nothing blocked: merge any non-blocking notes (verify soft tests + review
#    findings + gate result) and FILE them instead of printing them.
#
#    Why not just set suppressOutput: the harness yields `systemMessage`
#    unconditionally (utils/hooks.ts — `if (result.systemMessage)` at the end of
#    runHook), while `suppressOutput` only gates the separate plain-text
#    "<hook> completed" echo a few hundred lines earlier. So a
#    {"systemMessage":…,"suppressOutput":true} object — which is what this
#    emitted until 2026-07-27 — still printed the message in full. The only way
#    to keep the checks running silently is to not emit the field at all.
#
#    The checks themselves are UNCHANGED and still run every stop; blocking
#    paths (exit 2, above) are untouched so enforcement and the model-facing
#    feedback still work. Non-blocking notes land in $NOTES, newest run last.
#    Set SERGE_STOP_NOTES_CONSOLE=1 to restore the old on-screen behaviour. ──
NOTES="${SERGE_STOP_NOTES_FILE:-$SH/last-stop-notes.md}"
python3 - "$vout" "$rout" "$gout" "$NOTES" "${SERGE_STOP_NOTES_CONSOLE:-0}" <<'PY'
import json, sys, datetime
def msg(p):
    try:
        return (json.load(open(p)).get("systemMessage") or "").strip()
    except Exception:
        return ""
parts = [m for m in (msg(sys.argv[1]), msg(sys.argv[2]), msg(sys.argv[3])) if m]
if not parts:
    sys.exit(0)
body = "\n\n".join(parts)
notes, to_console = sys.argv[4], sys.argv[5] == "1"
try:
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(notes, "a") as f:
        f.write(f"\n## {stamp}\n\n{body}\n")
except Exception:
    to_console = True          # never silently lose a note we cannot file
if to_console:
    print(json.dumps({"systemMessage": body}))
PY
exit 0
