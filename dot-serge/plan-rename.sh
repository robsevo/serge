#!/usr/bin/env bash
# Give a shelved plan a name a human can recognise ($0, no LLM).
#
# WHY: the engine names every plan with a random per-session slug —
# `clever-soaring-reef.md`, `noble-mixing-lovelace.md`. Nothing about that says
# what the plan is, so a shelf of 28 plans is 28 files you have to open one by
# one. The plan's own title is right there on line 1 and was never used.
#
#   before  clever-soaring-reef.md
#   after   2026-07-22-integrate-ad-free-stream-sources-into-example-web.md
#
# Date first so the shelf sorts chronologically in any listing; title after so
# it is identifiable without opening it. Subagent fragments
# (<slug>-agent-<id>.md) are renamed WITH their parent — they are pieces of one
# plan, and orphaning them would break the grouping plans-list.sh shows.
#
# Single source of truth for the naming rule: persist-plan.sh calls this for new
# plans, `plans-list.sh --tidy` calls it for the backlog. Idempotent — a file
# already named `YYYY-MM-DD-...` is left alone, so it is safe to re-run.
#
# Usage: plan-rename.sh <plan-file>        prints the final path (renamed or not)
# Always exits 0: a plan that cannot be renamed is still a usable plan.
set -uo pipefail

f="${1:-}"
[ -n "$f" ] && [ -f "$f" ] || { echo "${f:-}"; exit 0; }

dir="$(dirname "$f")"
base="$(basename "$f" .md)"

# Already in the new shape, or is itself a fragment → nothing to do.
case "$base" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*) echo "$f"; exit 0 ;;
  *-agent-*) echo "$f"; exit 0 ;;
esac

# A heading is only a NAME if it says what the plan is about. Plans often open
# with a boilerplate section heading instead — one real plan led with "# Context"
# and would have been filed as `2026-07-22-context.md`, which is no more findable
# than the random slug it replaced. Skip those and keep looking; the first prose
# line is a better name than a generic label.
GENERIC='^(context|goal|goals|summary|overview|background|plan|objective|objectives|current state|problem|approach|steps|tasks|notes|intro|introduction|scope|requirements)$'
title=""
while IFS= read -r h; do
  h="$(printf '%s' "$h" | sed 's/^#\+[[:space:]]*//; s/^[Pp]lan:[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$h" ] || continue
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | grep -qE "$GENERIC" && continue
  title="$h"; break
done < <(grep -m6 '^#\+ ' "$f" 2>/dev/null)
[ -n "$title" ] || title="$(grep -m1 -E '^[^[:space:]#]' "$f" 2>/dev/null)"
[ -n "$title" ] || { echo "$f"; exit 0; }   # untitled: leave the slug alone

slug="$(printf '%s' "$title" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]\+/-/g; s/^-\+//; s/-\+$//' \
  | cut -c1-44 | sed 's/-\+$//')"
[ -n "$slug" ] || { echo "$f"; exit 0; }

# GNU `date -r FILE` vs BSD `date -r SECONDS` — same flag, different command.
# Probe rather than guess from uname, so a Mac with GNU date works too.
if date -r "$0" '+%Y' >/dev/null 2>&1; then
  date_prefix="$(date -r "$f" '+%Y-%m-%d' 2>/dev/null)" || date_prefix=""
else
  _s="$(stat -f %m "$f" 2>/dev/null)" || _s=""
  [ -n "$_s" ] && date_prefix="$(date -r "$_s" '+%Y-%m-%d' 2>/dev/null)" || date_prefix=""
fi
[ -n "$date_prefix" ] || date_prefix="$(date '+%Y-%m-%d')"

new_base="${date_prefix}-${slug}"
if [ -e "$dir/$new_base.md" ]; then
  i=2
  while [ -e "$dir/${new_base}-${i}.md" ] && [ "$i" -lt 50 ]; do i=$((i+1)); done
  new_base="${new_base}-${i}"
fi

# `mv -n` exits 0 even when it SKIPS an existing target (verified on this box),
# so the `||` branch alone cannot detect a refused move. Without the follow-up
# check, a skipped rename would still fall through to the fragment loop below
# and re-point every fragment at a parent that was never created — orphaning
# them, which is the exact opposite of what that loop is for — and then echo a
# path belonging to a DIFFERENT plan. The collision loop above normally makes
# the name unique first; this covers the two cases it cannot: 50+ collisions,
# and a concurrent rename landing between the check and the move.
mv -n "$f" "$dir/$new_base.md" 2>/dev/null || { echo "$f"; exit 0; }
[ -e "$dir/$new_base.md" ] && [ ! -e "$f" ] || { echo "$f"; exit 0; }

# Keep the fragments attached to their parent.
for frag in "$dir/$base"-agent-*.md; do
  [ -e "$frag" ] || continue
  suffix="${frag##*-agent-}"
  mv -n "$frag" "$dir/${new_base}-agent-${suffix}" 2>/dev/null || true
done

echo "$dir/$new_base.md"
exit 0
