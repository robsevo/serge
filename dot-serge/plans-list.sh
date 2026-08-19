#!/usr/bin/env bash
# Browse and reopen shelved plans ($0, no LLM — pure filesystem).
#
# WHY: every plan Serge writes lands in ~/.serge/plans/<random-slug>.md. The slug
# is per-session and meaningless ("clever-soaring-reef"), so a plan you approved
# last week is effectively lost the moment the session ends — persist-plan.sh
# says as much in its own header ("a random per-session slug that a fresh
# executor session can't find"). It copies only the LATEST approved plan to
# <repo>/plan.md; everything before that is on the shelf with no way in.
# Measured on this machine: 28 plans, none findable by name.
#
# This lists them by date and TITLE, prints one on request, and can promote one
# back to <repo>/plan.md — the same stable location persist-plan.sh writes, so
# an adopted plan is picked up by exactly the machinery that already exists.
#
# Subagent fragments (<slug>-agent-<id>.md) are grouped under their parent
# rather than listed: they are pieces of one plan, not 39 separate plans.
#
# Usage:
#   plans-list.sh                     list recent plans (default 15)
#   plans-list.sh --list 30           list more
#   plans-list.sh --all               list every plan
#   plans-list.sh --show <n|slug>     print one plan in full
#   plans-list.sh --outline <n|slug>  headings + phases + files only (cheap)
#   plans-list.sh --adopt <n|slug>    copy it to <repo>/plan.md (prints the path)
#   plans-list.sh --tidy              rename the backlog to date-title names
#   plans-list.sh --delete <n|slug>   shelve-to-trash (accepts 3,7,12)
#
# Selection accepts the list NUMBER or any unique part of the slug/title.
#
# Toggles: SERGE_PLANS_DIR (default ~/.serge/plans)
set -uo pipefail

PLANS_DIR="${SERGE_PLANS_DIR:-$HOME/.serge/plans}"
MODE="list"; ARG=""; LIMIT=15

while [ $# -gt 0 ]; do
  case "$1" in
    --list)  MODE="list";  [ $# -ge 2 ] && case "$2" in ''|*[!0-9]*) ;; *) LIMIT="$2"; shift;; esac; shift ;;
    --all)   MODE="list";  LIMIT=100000; shift ;;
    --show)  MODE="show";  ARG="${2:-}"; shift 2 || shift ;;
    --outline) MODE="outline"; ARG="${2:-}"; shift 2 || shift ;;
    --adopt) MODE="adopt"; ARG="${2:-}"; shift 2 || shift ;;
    --tidy)  MODE="tidy"; shift ;;
    --delete|--rm) MODE="delete"; ARG="${2:-}"; shift 2 || shift ;;
    -h|--help) sed -n '18,26p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

[ -d "$PLANS_DIR" ] || { echo "No plans directory yet ($PLANS_DIR) — nothing has been shelved."; exit 0; }

# Main plans only, newest first. Agent fragments are counted, not listed.
#
# Read into the array with a while-loop rather than `mapfile`: mapfile is a bash
# 4.0 builtin and macOS still ships bash 3.2 as /bin/bash, where it does not
# exist at all. Unlike the GNU/BSD tool differences elsewhere in serge, this one
# is NOT fixed by `brew install coreutils` — it is the shell itself — so a
# mapfile here would break `/plans` on a stock Mac with no obvious cause.
# The agent-fragment filter is ANCHORED to the generated suffix (2026-08-15).
# It used to be a bare `grep -v -- '-agent-'` over the full path, which hides any
# plan with "agent" between two hyphens ANYWHERE — so a legitimately-titled
# "agent-roster-audit" or "multi-agent-orchestration" plan would silently vanish
# from /plans with no error and no count. Verified against the live corpus: the
# anchored form hides the same 39 fragments and stops hiding those three.
# Matching the full path also meant a PLANS_DIR containing "-agent-" would filter
# everything; anchoring to <name>-agent-<hex>.md removes that too.
#
# NOTE: keep this comment ABOVE the loop. Placing it between `done` and its
# `< <(...)` redirect still runs, but shellcheck cannot parse the file at all —
# and a file shellcheck cannot parse is a file shellcheck does not check.
#
PLANS=()
# shellcheck disable=SC2010  # ls -t IS the sort; slugs are generated [a-z0-9-]
while IFS= read -r _p; do
  [ -n "$_p" ] && PLANS+=("$_p")
done < <(ls -t "$PLANS_DIR"/*.md 2>/dev/null | grep -vE -- '-agent-[0-9a-f]{8,}\.md$' || true)
[ "${#PLANS[@]}" -gt 0 ] || { echo "No shelved plans in $PLANS_DIR."; exit 0; }

# GNU `date -r FILE` and BSD `date -r SECONDS` are different commands wearing the
# same flag: on macOS without gnubin first on PATH, `date -r plan.md` does not
# error usefully, it just fails to produce a date. Probe the capability once
# rather than guessing from `uname`, so this is correct on a Mac with GNU date
# installed AND on one without.
if date -r "$0" '+%Y' >/dev/null 2>&1; then _DATE_MODE=gnu; else _DATE_MODE=bsd; fi
mtime_fmt() {  # mtime_fmt <file> <strftime-format>
  if [ "$_DATE_MODE" = gnu ]; then
    date -r "$1" "+$2" 2>/dev/null && return 0
  else
    local _s
    _s="$(stat -f %m "$1" 2>/dev/null)" && date -r "$_s" "+$2" 2>/dev/null && return 0
  fi
  printf '????-??-?? ??:??'   # never let a date failure break the listing
}

title_of() {  # first markdown heading, else first real line, else the slug
  local f="$1" t
  t="$(grep -m1 '^#\+ ' "$f" 2>/dev/null | sed 's/^#\+[[:space:]]*//; s/^Plan:[[:space:]]*//')"
  [ -n "$t" ] || t="$(grep -m1 -E '^[^[:space:]#]' "$f" 2>/dev/null | cut -c1-70)"
  [ -n "$t" ] || t="(untitled) $(basename "$f" .md)"
  printf '%s' "$t"
}

resolve() {  # number or slug/title substring -> file path
  local want="$1" i=0
  case "$want" in
    ''|*[!0-9]*) : ;;
    *) i="$want"
       [ "$i" -ge 1 ] && [ "$i" -le "${#PLANS[@]}" ] && { printf '%s' "${PLANS[$((i-1))]}"; return 0; }
       return 1 ;;
  esac
  local f hits=() lw
  lw="$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]')"
  for f in "${PLANS[@]}"; do
    if printf '%s %s' "$(basename "$f" .md)" "$(title_of "$f")" \
         | tr '[:upper:]' '[:lower:]' | grep -qF -- "$lw"; then
      hits+=("$f")
    fi
  done
  [ "${#hits[@]}" -eq 1 ] && { printf '%s' "${hits[0]}"; return 0; }
  # Ambiguous or absent: say which, rather than guessing at a plan the user
  # then has to un-adopt.
  if [ "${#hits[@]}" -gt 1 ]; then
    { echo "'$want' matches ${#hits[@]} plans:"; for f in "${hits[@]}"; do
        echo "  - $(basename "$f" .md) — $(title_of "$f")"; done
      echo "Be more specific, or use the list number."; } >&2
  fi
  return 1
}

case "$MODE" in
  list)
    echo "Shelved plans in $PLANS_DIR (newest first):"
    echo
    i=0
    for f in "${PLANS[@]}"; do
      i=$((i+1)); [ "$i" -gt "$LIMIT" ] && break
      slug="$(basename "$f" .md)"
      frags=$(ls "$PLANS_DIR/$slug"-agent-*.md 2>/dev/null | wc -l | tr -d ' ')
      extra=""; [ "${frags:-0}" -gt 0 ] && extra=" · ${frags} agent note(s)"
      printf '  %2d. %s  %s\n' "$i" "$(mtime_fmt "$f" '%Y-%m-%d %H:%M')" "$(title_of "$f")"
      printf '      %s · %sKB%s\n' "$slug" "$(( ($(wc -c < "$f") + 512) / 1024 ))" "$extra"
    done
    total="${#PLANS[@]}"
    [ "$total" -gt "$LIMIT" ] && { echo; echo "  … $((total - LIMIT)) older (plans-list.sh --all)"; }
    echo
    echo "Pick one by number or name: plans-list.sh --show <n>"
    ;;

  show)
    f="$(resolve "$ARG")" || { echo "No plan matches '$ARG'. Run plans-list.sh to see them." >&2; exit 1; }
    echo "PLAN FILE: $f"
    echo "SAVED:     $(mtime_fmt "$f" '%Y-%m-%d %H:%M')"
    echo "TITLE:     $(title_of "$f")"
    slug="$(basename "$f" .md)"
    frags=$(ls "$PLANS_DIR/$slug"-agent-*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "${frags:-0}" -gt 0 ] && echo "NOTE:      ${frags} subagent note(s) exist alongside this plan"
    echo "---"
    cat "$f"
    ;;

  outline)
    # The SHAPE of a plan without its prose. A summary should be grounded in the
    # plan's real structure rather than reconstructed from a 10KB read — 19 of
    # the 28 plans here carry explicit Phase/Step headings, so the skeleton is
    # already written down. Cheap enough to run before deciding to read more.
    f="$(resolve "$ARG")" || { echo "No plan matches '$ARG'. Run plans-list.sh to see them." >&2; exit 1; }
    echo "PLAN:  $(title_of "$f")"
    echo "SAVED: $(mtime_fmt "$f" '%Y-%m-%d %H:%M') · $(( ($(wc -c < "$f") + 512) / 1024 ))KB · $(wc -l < "$f") lines"
    echo
    echo "STRUCTURE"
    command grep -E '^#{1,4} ' "$f" 2>/dev/null | sed -E 's/^# /  /; s/^## /    /; s/^### /      /; s/^#### /        /' || true
    steps=$(command grep -cE '^[[:space:]]*([0-9]+\.|[-*] \[[ xX]\])' "$f" 2>/dev/null || echo 0)
    [ "${steps:-0}" -gt 0 ] && { echo; echo "STEPS: $steps numbered or checkbox items"; }
    # Paths the plan names — the closest thing to "which features it touches"
    # that can be read without a model.
    files=$(command grep -ohE '[A-Za-z0-9_./-]+\.(ts|tsx|js|jsx|mjs|py|sh|json|yaml|yml|md|css|html|go|rs)' "$f" 2>/dev/null \
            | sort -u | head -20)
    if [ -n "$files" ]; then
      echo; echo "FILES MENTIONED"
      printf '%s\n' "$files" | sed 's/^/  /'
    fi
    echo; echo "(full text: plans-list.sh --show $ARG)"
    ;;

  adopt)
    f="$(resolve "$ARG")" || { echo "No plan matches '$ARG'. Run plans-list.sh to see them." >&2; exit 1; }
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
    [ -n "$root" ] || root="$PWD"
    target="$root/${SERGE_PLAN_FILE:-plan.md}"
    # Never clobber a different plan silently — the previous one may be live work.
    if [ -f "$target" ] && ! cmp -s "$f" "$target"; then
      bak="$target.replaced-$(date +%Y%m%d-%H%M%S)"
      cp -p "$target" "$bak" 2>/dev/null && echo "PREVIOUS plan.md backed up to: $bak"
    fi
    cp "$f" "$target" 2>/dev/null || { echo "Could not write $target" >&2; exit 1; }
    echo "ADOPTED: $(title_of "$f")"
    echo "WRITTEN: $target"
    echo "SOURCE:  $f"
    ;;
  delete)
    # NOT `rm`. A plan is the most expensive artefact in the session that
    # produced it — sometimes hours of research — and "delete the wrong one by
    # number" is a mistake with no undo. Move to .trash/ instead: the shelf is
    # clean immediately, the file is recoverable, and old trash prunes itself.
    TRASH="$PLANS_DIR/.trash"
    mkdir -p "$TRASH" 2>/dev/null || { echo "Cannot create $TRASH" >&2; exit 1; }
    [ -n "$ARG" ] || { echo "Nothing selected. Use --delete <n|name>." >&2; exit 1; }

    # Resolve EVERY selection before deleting anything: list numbers shift the
    # moment a file moves, so deleting 3 then 7 would delete the wrong 7.
    targets=()
    IFS=',' read -ra wants <<< "$ARG"
    for w in "${wants[@]}"; do
      w="$(printf '%s' "$w" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$w" ] || continue
      t="$(resolve "$w")" || { echo "No plan matches '$w' — nothing deleted." >&2; exit 1; }
      targets+=("$t")
    done
    [ "${#targets[@]}" -gt 0 ] || { echo "Nothing to delete." >&2; exit 1; }

    stamp="$(date +%Y%m%d-%H%M%S)"
    for f in "${targets[@]}"; do
      slug="$(basename "$f" .md)"
      echo "TRASHED: $(title_of "$f")"
      mv "$f" "$TRASH/${stamp}-${slug}.md" 2>/dev/null || { echo "  could not move $f" >&2; continue; }
      for frag in "$PLANS_DIR/$slug"-agent-*.md; do
        [ -e "$frag" ] || continue
        mv "$frag" "$TRASH/${stamp}-$(basename "$frag")" 2>/dev/null || true
      done
    done
    # Self-pruning so the trash never becomes a second shelf.
    find "$TRASH" -maxdepth 1 -name '*.md' -mtime +30 -delete 2>/dev/null || true
    echo "RECOVER: $TRASH (auto-pruned after 30 days)"
    ;;

  tidy)
    # Retroactive naming for plans shelved before plan-rename.sh existed.
    # Idempotent: already-named plans and fragments are skipped by the renamer.
    RENAMER="${SERGE_PLAN_RENAMER:-$HOME/.serge/plan-rename.sh}"
    [ -x "$RENAMER" ] || [ -f "$RENAMER" ] || { echo "Renamer not found: $RENAMER" >&2; exit 1; }
    changed=0; kept=0
    for f in "${PLANS[@]}"; do
      before="$(basename "$f")"
      after="$(bash "$RENAMER" "$f" 2>/dev/null)"
      if [ "$(basename "${after:-$f}")" != "$before" ]; then
        printf '  %s\n    -> %s\n' "$before" "$(basename "$after")"
        changed=$((changed+1))
      else
        kept=$((kept+1))
      fi
    done
    echo
    echo "Renamed $changed plan(s); $kept already named or untitled."
    ;;
esac
exit 0
