#!/usr/bin/env bash
# Regression test for stream_check.py — starts a real FastAPI server, verifies genuine streams
# PASS and the deliberately-buffered endpoint FAILS. Negative-controlled: a stream checker that
# can't tell buffered from streaming is worse than none (it certifies the bug).
#   ./test_streaming.sh   → exit 0 = checker trustworthy
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PY="${SERGE_BACKEND_PY:-$HOME/.serge/office-venv/bin/python}"
PORT="${PORT:-8079}"
n=0; fail=0
ck(){ n=$((n+1)); if [ "$1" = "$2" ]; then echo "✓ $3"; else fail=$((fail+1)); echo "✗ $3 (want exit $1, got $2)"; fi; }

[ -x "$PY" ] || { echo "✗ backend python not found at $PY (see SKILL.md → runtime)"; exit 2; }

"$PY" "$DIR/templates/streaming_api.py" "$PORT" >/tmp/serge-stream-test.log 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT

# wait for readiness rather than a fixed sleep
for _ in $(seq 1 40); do
  curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 || { echo "✗ server never became healthy"; cat /tmp/serge-stream-test.log; exit 1; }

"$PY" "$DIR/stream_check.py" "http://127.0.0.1:$PORT/stream/chunked" >/dev/null 2>&1
ck 0 $? "chunked stream verified as genuinely streaming"

"$PY" "$DIR/stream_check.py" "http://127.0.0.1:$PORT/stream/sse" --sse >/dev/null 2>&1
ck 0 $? "SSE stream verified as genuinely streaming"

"$PY" "$DIR/stream_check.py" "http://127.0.0.1:$PORT/stream/BUFFERED-WRONG" >/dev/null 2>&1
ck 1 $? "NEGATIVE CONTROL: buffered endpoint correctly rejected"

"$PY" "$DIR/stream_check.py" "http://127.0.0.1:$PORT/nonexistent" >/dev/null 2>&1
ck 1 $? "404 endpoint fails loudly (not a silent pass)"

echo ""
[ $fail -eq 0 ] && echo "✓ ALL $n PASS — stream checker is trustworthy" || echo "✗ $fail/$n FAILED"
exit $((fail == 0 ? 0 : 1))
