#!/usr/bin/env bash
# Serge history retention — prune conversation transcripts and file snapshots.
#
# WHY SIZE BEFORE AGE (measured 2026-07-27):
#   file-history/  172MB total — but SIX 21.5MB snapshots in one session dir
#                  accounted for 129MB of it. Those are dist/cli.mjs, snapshotted
#                  @v1/@v2 on each build. A 22MB build artifact is never worth
#                  diffing, and it dwarfs every real source snapshot (next
#                  largest: 1.2MB).
#   projects/      291MB — one 67.6MB .jsonl transcript plus several 11.2MB
#                  tool-result blobs.
#   Age profile:   ZERO files older than 90d; only ~19MB older than 30d. So
#                  age-based pruning alone would delete ~274 files and reclaim
#                  almost nothing. Size is the lever; age is the tidy-up.
#
# WHY THIS IS A PRIVACY CONTROL, not just disk hygiene: these files are the
# complete text of past sessions — prompts, file contents, command output. They
# are owner-only now, but the best-protected data is data no longer held.
#
# SAFETY
#   - Dry-run by DEFAULT. Deletion requires an explicit --apply.
#   - Never touches anything modified in the last $FLOOR_HOURS hours, so the
#     live session and its undo history are always safe regardless of rules.
#   - Never touches sessions/, history.jsonl, memory/, or any config.
#
# USAGE
#   prune-history.sh                        # dry run, defaults
#   prune-history.sh --days 30 --max-mb 5   # dry run, custom
#   prune-history.sh --apply                # actually delete
set -uo pipefail

SH="${SERGE_HOME:-$HOME/.serge}"
DAYS="${SERGE_PRUNE_DAYS:-30}"     # age rule: transcripts/snapshots older than this
MAX_MB="${SERGE_PRUNE_MAX_MB:-5}"  # size rule: any snapshot/blob larger than this
FLOOR_HOURS=24                     # absolute protection window
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    --days)    DAYS="$2"; shift ;;
    --max-mb)  MAX_MB="$2"; shift ;;
    --dry-run) APPLY=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$SH/projects" ] || { echo "no $SH/projects — nothing to do"; exit 0; }

MAX_BYTES=$((MAX_MB * 1048576))
FLOOR_MIN=$((FLOOR_HOURS * 60))

# Candidates. -mmin +$FLOOR_MIN is applied to EVERY rule so the live session is
# never a candidate, whatever its size.
list_oversized() {
  find "$SH/file-history" "$SH/projects" -type f -mmin +$FLOOR_MIN \
       -size +${MAX_BYTES}c 2>/dev/null
}
list_aged() {
  find "$SH/file-history" "$SH/projects" -type f -mmin +$FLOOR_MIN \
       -mtime +"$DAYS" 2>/dev/null
}

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
{ list_oversized; list_aged; } | sort -u > "$TMP"

COUNT=$(wc -l < "$TMP")
if [ "$COUNT" -eq 0 ]; then
  echo "Nothing to prune (>${MAX_MB}MB or >${DAYS}d, excluding last ${FLOOR_HOURS}h)."
  exit 0
fi
BYTES=$(tr '\n' '\0' < "$TMP" | xargs -0 -r stat -c '%s' 2>/dev/null | awk '{s+=$1} END {print s+0}')

printf 'Rules: size > %s MB  OR  age > %s days   (protected: modified in last %sh)\n' \
       "$MAX_MB" "$DAYS" "$FLOOR_HOURS"
printf 'Matches: %s files, %.1f MB\n\n' "$COUNT" "$(awk -v b="$BYTES" 'BEGIN{print b/1048576}')"
echo "Largest 10:"
tr '\n' '\0' < "$TMP" | xargs -0 -r stat -c '%s	%n' 2>/dev/null \
  | sort -rn | head -10 | awk -F'\t' '{printf "  %7.1f MB  %s\n", $1/1048576, $2}'

if [ "$APPLY" != "1" ]; then
  echo
  echo "DRY RUN — nothing deleted. Re-run with --apply to delete these ${COUNT} files."
  exit 0
fi

echo
tr '\n' '\0' < "$TMP" | xargs -0 -r rm -f
# Drop directories left empty by the deletions (never the roots themselves).
find "$SH/file-history" "$SH/projects" -mindepth 1 -type d -empty -delete 2>/dev/null
printf 'Deleted %s files, reclaimed %.1f MB.\n' \
       "$COUNT" "$(awk -v b="$BYTES" 'BEGIN{print b/1048576}')"
echo "Now: projects $(du -sh "$SH/projects" 2>/dev/null | cut -f1), file-history $(du -sh "$SH/file-history" 2>/dev/null | cut -f1)"
