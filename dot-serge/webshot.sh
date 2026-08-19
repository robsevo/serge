#!/usr/bin/env bash
# Serge web screenshot — "eyes" on a page. EXPLICIT INVOCATION ONLY.
#
# Renders a URL with headless Chrome and writes a PNG. Serge then Reads that PNG
# (FileReadTool already returns image blocks), so the model literally sees the
# rendered page rather than its extracted markdown.
#
# WHEN TO USE THIS: only when text extraction is insufficient — JS-rendered
# apps, canvas, charts, image-only pages, or "does this layout look right".
# WebFetch is the default path and is far cheaper: it summarizes a 43KB page to
# ~560 chars, where a screenshot costs thousands of tokens. Reaching for eyes by
# habit is a large, silent token bill.
#
# NO NEW DEPENDENCIES: uses the google-chrome-stable already installed on this
# box. Deliberately NOT Playwright/Puppeteer — this box has a history of heavy
# local deps causing trouble, and a screenshot needs none of it.
#
# VISION SEAT REQUIRED: the PNG is useless unless the CURRENT seat accepts
# images. Gemini seats do; mistral-large (local-coder) does not. This script
# warns when the configured seat looks non-vision rather than letting the model
# receive an image it cannot read.
#
# PRIVACY: a screenshot of a page is sent to whichever provider serves the seat.
# Gemini's free tier trains on submitted data and human-reviews it. Fine for
# public pages; do NOT point this at anything behind a login.
#
# USAGE
#   webshot.sh <url> [out.png]
#   webshot.sh https://example.com            # -> prints the PNG path
#   WEBSHOT_HEIGHT=4000 webshot.sh <url>      # taller capture for long pages
set -uo pipefail

CHROME="${WEBSHOT_CHROME:-$(command -v google-chrome-stable || command -v chromium || command -v chromium-browser || true)}"
WIDTH="${WEBSHOT_WIDTH:-1280}"
HEIGHT="${WEBSHOT_HEIGHT:-2000}"
TIMEOUT="${WEBSHOT_TIMEOUT:-45}"
MAX_MB="${WEBSHOT_MAX_MB:-4}"

die() { echo "webshot: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: webshot.sh <url> [out.png]"
URL="$1"
OUT="${2:-}"

case "$URL" in
  http://*|https://*) ;;
  *) die "url must start with http:// or https:// (got: $URL)" ;;
esac
[ -n "$CHROME" ] || die "no chrome/chromium binary found; set WEBSHOT_CHROME"

if [ -z "$OUT" ]; then
  OUT="$(mktemp -t "webshot-XXXXXX.png")"
fi

# Chrome writes the screenshot relative to CWD unless given an absolute path.
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac

# --no-sandbox is required when running as a service/container user; harmless
# here and avoids a class of silent failures. --virtual-time-budget gives the
# page a moment to settle so JS-rendered content actually appears — without it
# SPAs screenshot blank, which is the single most common way this looks broken.
INSECURE_FLAG=()
[ "${WEBSHOT_INSECURE:-0}" = "1" ] && INSECURE_FLAG=(--ignore-certificate-errors)

COMMON=(
  --headless
  --disable-gpu
  --no-sandbox
  --hide-scrollbars
  --virtual-time-budget=5000
  "${INSECURE_FLAG[@]+"${INSECURE_FLAG[@]}"}"
)

timeout "$TIMEOUT" "$CHROME" \
  "${COMMON[@]}" \
  --window-size="${WIDTH},${HEIGHT}" \
  --screenshot="$OUT" \
  "$URL" >/dev/null 2>&1
rc=$?

[ -s "$OUT" ] || die "no image produced (chrome exit $rc). Page may have blocked headless, timed out after ${TIMEOUT}s, or needs a login."

# A screenshot of an ERROR PAGE is still a valid PNG and still exits 0. Observed
# 2026-07-27: a self-signed cert produced a clean capture of Chrome's "Your
# connection is not private" interstitial — success by every mechanical measure,
# and completely the wrong content. Silent wrong-content is worse than a clean
# failure, because the model then confidently describes an error page as if it
# were the site. So dump the DOM and check for Chrome's own error markers.
DOM="$(timeout "$TIMEOUT" "$CHROME" "${COMMON[@]}" --dump-dom "$URL" 2>/dev/null | head -c 20000)"
# Match on the TITLE first. Chrome's cert interstitial carries NO "ERR_CERT"
# string in its DOM at all (verified 2026-07-27 — the whole document is ~3KB and
# the error code lives in a collapsed section), so code-marker matching alone
# silently passed it. The <title> is the stable signal across error types.
ERRKIND=""
case "$DOM" in
  *"<title>Privacy error</title>"*)  ERRKIND="TLS certificate rejected — set WEBSHOT_INSECURE=1 for a self-signed host" ;;
  *"ERR_NAME_NOT_RESOLVED"*)         ERRKIND="DNS did not resolve" ;;
  *"ERR_CONNECTION_"*)               ERRKIND="connection failed" ;;
  *"ERR_CERT"*)                      ERRKIND="TLS certificate rejected — set WEBSHOT_INSECURE=1 for a self-signed host" ;;
  *'id="main-frame-error"'*|*"main-frame-error"*) ERRKIND="Chrome error page" ;;
  *"HTTP ERROR 4"*|*"HTTP ERROR 5"*) ERRKIND="HTTP error response" ;;
  *"<title>Error</title>"*)          ERRKIND="Chrome error page" ;;
esac

if [ -n "$ERRKIND" ]; then
  echo "$OUT"
  echo "webshot: WARNING — the capture is an ERROR PAGE, not the site: $ERRKIND" >&2
  echo "webshot: do NOT describe this screenshot as the page's content." >&2
  exit 3
fi

BYTES=$(stat -c '%s' "$OUT" 2>/dev/null || echo 0)
MB=$(awk -v b="$BYTES" 'BEGIN{printf "%.1f", b/1048576}')

echo "$OUT"
echo "webshot: ${WIDTH}x${HEIGHT}, ${MB} MB" >&2

if awk -v b="$BYTES" -v m="$MAX_MB" 'BEGIN{exit !(b > m*1048576)}'; then
  echo "webshot: WARNING ${MB} MB exceeds ${MAX_MB} MB — this will be expensive in context." >&2
  echo "webshot: consider a smaller WEBSHOT_HEIGHT, or use WebFetch instead." >&2
fi

# Vision-seat check. Non-fatal: the seat can be overridden per-launch, and a
# wrong guess here should not block a capture the user explicitly asked for.
SEAT="${OPENAI_MODEL:-unknown}"
case "$SEAT" in
  *flash*|*gemini*|*brain*|*pro-coder*|*sonnet*|*opus*|*haiku*) ;;
  unknown) ;;
  *)
    echo "webshot: NOTE current seat '$SEAT' may not accept images (mistral-large does not)." >&2
    echo "webshot: if the model cannot see the screenshot, relaunch with: serge --cloud" >&2
    ;;
esac
