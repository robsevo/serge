#!/usr/bin/env bash
# tabarnak — autonomous story-by-story build loop for serge.
# Ported from snarktank/ralph (MIT; renamed tabarnak per user), adapted to the serge stack 2026-07-21.
#
# The idea (Tabarnak technique): drive a product PRD with a FRESH serge session
# per story — clean context every iteration, no context rot — and let the
# RUNNER, not the model, decide when a box is checked: each story carries a
# deterministic `test` command, and passes=true is written ONLY when that
# command exits 0. progress.txt carries learnings across iterations. This is
# the feature-flow doctrine (one feature, BUILD→TEST→CONFIRM) automated.
#
# Usage:
#   tabarnak.sh --prd prd.json [--dir .] [--max 10] [--same-fail-cap 3]
#
# prd.json shape (see SKILL.md for a worked example):
#   { "stories": [ { "id": "s1", "priority": 1, "story": "...",
#       "acceptance": "...", "test": "shell command, exit 0 = pass",
#       "passes": false } ] }
#
# Controls:
#   touch <dir>/TABARNAK.STOP     — graceful stop before the next iteration
#   TABARNAK_SERGE_BIN            — serge binary (tests stub this)
#   TABARNAK_SERGE_ENV            — env file for headless runs (default: bench.env)
#   TABARNAK_TIMEOUT              — per-iteration timeout seconds (default 900)
#
# Exit codes: 0 = all stories pass (COMPLETE); 3 = stopped (STOP file /
# max iterations / same-story failure cap); 1 = config error. Always loud.
set -uo pipefail

PRD=""; DIR="."; MAX=10; SAME_FAIL_CAP=3
while [ $# -gt 0 ]; do
  case "$1" in
    --prd) PRD="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    --same-fail-cap) SAME_FAIL_CAP="$2"; shift 2 ;;
    *) echo "tabarnak: unknown arg $1" >&2; exit 1 ;;
  esac
done
[ -n "$PRD" ] || { echo "tabarnak: --prd required" >&2; exit 1; }
cd "$DIR" || { echo "tabarnak: bad --dir $DIR" >&2; exit 1; }
[ -f "$PRD" ] || { echo "tabarnak: prd not found: $PRD" >&2; exit 1; }
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get('stories'), list) and d['stories'], 'stories[] missing/empty'" "$PRD" \
  || { echo "tabarnak: malformed prd — need non-empty stories[]" >&2; exit 1; }

SERGE="${TABARNAK_SERGE_BIN:-$HOME/programs/serge-0.1.0/serge}"
SERGE_ENV="${TABARNAK_SERGE_ENV:-$HOME/.serge/evals/swe/bench.env}"
TIMEOUT="${TABARNAK_TIMEOUT:-900}"
PROG="progress.txt"
note() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$PROG"; }

pick_story() {  # → "id<TAB>story<TAB>acceptance<TAB>test" of highest-priority failing story, or ""
  python3 - "$PRD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
open_stories = [s for s in d["stories"] if not s.get("passes")]
if not open_stories:
    sys.exit(0)
s = sorted(open_stories, key=lambda s: s.get("priority", 999))[0]
print("\t".join([str(s.get("id", "?")), s.get("story", ""), s.get("acceptance", ""), s.get("test", "")]))
PY
}

mark_pass() {  # $1 = story id
  SID="$1" python3 - "$PRD" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p))
for s in d["stories"]:
    if str(s.get("id")) == os.environ["SID"]:
        s["passes"] = True
tmp = p + ".tmp"
json.dump(d, open(tmp, "w"), indent=2)
os.replace(tmp, p)
PY
}

same_fail_id=""; same_fail_n=0
for i in $(seq 1 "$MAX"); do
  [ -f TABARNAK.STOP ] && { echo "tabarnak: TABARNAK.STOP present — stopping."; note "STOP file — halted at iteration $i"; exit 3; }
  line="$(pick_story)"
  if [ -z "$line" ]; then
    echo "tabarnak: <promise>COMPLETE</promise> — all stories pass."
    note "COMPLETE after $((i - 1)) iteration(s)"
    exit 0
  fi
  IFS=$'\t' read -r sid story acceptance testcmd <<< "$line"
  [ -n "$testcmd" ] || { echo "tabarnak: story $sid has no test command — refusing to run an ungated story" >&2; exit 1; }
  echo "tabarnak[$i/$MAX]: story $sid — $story"

  prompt="You are one iteration of an autonomous build loop. Work on EXACTLY ONE story, completely.
First read progress.txt if it exists (learnings from earlier iterations — do not repeat recorded mistakes).
STORY ($sid): $story
ACCEPTANCE: $acceptance
It is DONE only when this shell command exits 0:  $testcmd
Follow the feature-flow: BUILD it completely, TEST it by actually running that command, fix until it passes.
Do not touch other stories. Do not mark anything in $PRD — the runner owns that file.
Before finishing, append one line of durable learnings (gotchas, decisions) to progress.txt."

  timeout "$TIMEOUT" env SERGE_ENV_FILE="$SERGE_ENV" "$SERGE" --yolo -p "$prompt" > ".tabarnak-iter-$i.log" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && note "iteration $i (story $sid): serge exited rc=$rc (see .tabarnak-iter-$i.log)"

  # THE GATE: the runner, not the model, decides. Story test must exit 0.
  if ( eval "$testcmd" ) >/dev/null 2>&1; then
    mark_pass "$sid"
    note "story $sid PASSED its gate at iteration $i"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git add -A >/dev/null 2>&1 && git commit -q -m "tabarnak: story $sid passes its gate" >/dev/null 2>&1 || true
    fi
    same_fail_id=""; same_fail_n=0
    echo "tabarnak[$i/$MAX]: story $sid PASSED"
  else
    if [ "$same_fail_id" = "$sid" ]; then same_fail_n=$((same_fail_n + 1)); else same_fail_id="$sid"; same_fail_n=1; fi
    note "story $sid FAILED its gate at iteration $i (consecutive: $same_fail_n)"
    echo "tabarnak[$i/$MAX]: story $sid still failing its gate ($same_fail_n consecutive)"
    if [ "$same_fail_n" -ge "$SAME_FAIL_CAP" ]; then
      echo "tabarnak: story $sid failed its gate $same_fail_n times in a row — stopping LOUDLY (fix the story, its test, or the recorded blocker in progress.txt)." >&2
      exit 3
    fi
  fi
done
echo "tabarnak: max iterations ($MAX) reached with open stories remaining — stopping." >&2
note "max iterations reached"
exit 3
