#!/usr/bin/env bash
# Tests for seat-health.sh (fallback-masking detector, 2026-07-28).
# Zero real network: a stub HTTP server stands in for the litellm router and
# echoes whichever `model` the case under test needs.
set -uo pipefail

SH="${SERGE_SEAT_HEALTH_SCRIPT:-$HOME/.serge/seat-health.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"; [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

mkdir -p "$T/sergehome/monitor"
export SERGE_HOME="$T/sergehome"

# Seat map under test: a free seat, a multi-deployment pool, and a paid seat.
cat > "$T/sergehome/litellm.yaml" <<'YAML'
model_list:
  - model_name: local-coder
    litellm_params:
      model: mistral/mistral-large-latest
      api_key: os.environ/MISTRAL_API_KEY
  - model_name: free-qwen
    litellm_params:
      model: openrouter/nvidia/nemotron-3-super-120b-a12b:free
      api_key: os.environ/OPENROUTER_API_KEY
  - model_name: cheap-paid
    litellm_params:
      model: openrouter/qwen/qwen3-coder-next
      api_key: os.environ/OPENROUTER_PAID_API_KEY
  # The context-capped shape: Cerebras free hard-limits this model to 8,192
  # tokens, far below serge's ~74,700-token median request.
  - model_name: glm-coder
    litellm_params:
      model: cerebras/zai-glm-4.7
      api_key: os.environ/CEREBRAS_API_KEY
  # The restricted-by-design shape: documented in litellm.yaml as a small-request
  # lane (~30K TPM), so seat-health probes it at its own ceiling, not production size.
  - model_name: free-brain
    litellm_params:
      model: cerebras/gpt-oss-120b
      api_key: os.environ/CEREBRAS_API_KEY
YAML

# --- stub router: replies with $T/reply_model, or $T/reply_status if non-200 ---
cat > "$T/stub.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
D = sys.argv[1]
def _read(d, name):
    try:
        return open(os.path.join(d, name)).read().strip()
    except Exception:
        return ""

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        self.rfile.read(n)
        # Record the largest body seen, so a test can assert WHAT SIZE a seat was
        # probed at (the per-seat ceiling), not merely whether it passed.
        try:
            prev = int(_read(D, "max_body") or 0)
            if n > prev:
                open(os.path.join(D, "max_body"), "w").write(str(n))
        except Exception:
            pass
        # A big body is seat-health's stage-2 context probe. reply_model_big /
        # reply_status_big let a test model the real bug: a seat that answers a
        # 1-token probe from its own upstream but is context-capped for real work.
        big = n > 1000
        status = _read(D, "reply_status_big" if big else "reply_status")
        if big and not status:
            status = _read(D, "reply_status")
        status = int(status) if status else 200
        model = _read(D, "reply_model_big" if big else "reply_model")
        if big and not model:
            model = _read(D, "reply_model")
        self.send_response(status)
        self.send_header("Content-Type", "application/json"); self.end_headers()
        if status == 200:
            self.wfile.write(json.dumps({"model": model, "choices": []}).encode())
        else:
            self.wfile.write(b'{"error":{"message":"nope"}}')
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 "$T/stub.py" "$T" "$PORT" & STUB_PID=$!
export SERGE_SEAT_HEALTH_URL="http://127.0.0.1:$PORT/v1/chat/completions"
for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && break
  read -rt 0.1 < /dev/zero 2>/dev/null || true
done

reset() { echo 200 > "$T/reply_status"; rm -f "$T/reply_status_big" "$T/reply_model_big" \
          "$T/sergehome/NOTIFICATIONS.md" "$T/max_body"; }
maxbody() { cat "$T/max_body" 2>/dev/null || echo 0; }
notes() { grep -c 'seat-health' "$T/sergehome/NOTIFICATIONS.md" 2>/dev/null || echo 0; }

# 1. seat answered by its own model (provider prefix stripped in the response)
reset; echo 'mistral-large-latest' > "$T/reply_model"
out=$(bash "$SH" --seats local-coder); rc=$?
if [ "$rc" = "0" ] && echo "$out" | grep -q '^  ok ' && [ "$(notes)" = "0" ]; then
  ok "own model (prefix-stripped) → ok, no notification"
else bad "own model → ok (rc=$rc, notes=$(notes))"; echo "$out"; fi

# 2. a foreign model answering is the whole point of the check
reset; echo 'nvidia/nemotron-3-super-120b-a12b:free' > "$T/reply_model"
out=$(bash "$SH" --seats local-coder); rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q 'DRIFT' && [ "$(notes)" = "1" ]; then
  ok "foreign model → DRIFT, exit 1, one notification"
else bad "foreign model → DRIFT (rc=$rc, notes=$(notes))"; echo "$out"; fi

# 3. regression: a seat served by its own pool echoes the group alias, not a
#    model id. That is healthy and must not read as drift.
reset; echo 'free-qwen' > "$T/reply_model"
out=$(bash "$SH" --seats free-qwen); rc=$?
if [ "$rc" = "0" ] && echo "$out" | grep -q '^  ok '; then
  ok "group alias echoed back → ok (not drift)"
else bad "group alias → ok (rc=$rc)"; echo "$out"; fi

# 4. non-200 is DOWN, not drift
reset; echo 503 > "$T/reply_status"; echo 'x' > "$T/reply_model"
out=$(bash "$SH" --seats local-coder); rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q 'DOWN'; then
  ok "non-200 → DOWN"
else bad "non-200 → DOWN (rc=$rc)"; echo "$out"; fi

# 5. paid seats cost money — excluded unless asked for
reset; echo 'qwen/qwen3-coder-next' > "$T/reply_model"
out=$(bash "$SH" --seats cheap-paid); rc=$?
if echo "$out" | grep -q 'skipping paid seat'; then
  ok "paid seat skipped by default"
else bad "paid seat skipped by default"; echo "$out"; fi

out=$(bash "$SH" --seats cheap-paid --include-paid); rc=$?
if [ "$rc" = "0" ] && echo "$out" | grep -q '^  ok '; then
  ok "paid seat probed with --include-paid"
else bad "paid seat probed with --include-paid (rc=$rc)"; echo "$out"; fi

# 6. reruns must not spam the session-start loader
reset; echo 'some/other-model' > "$T/reply_model"
bash "$SH" --seats local-coder >/dev/null
bash "$SH" --seats local-coder >/dev/null
if [ "$(notes)" = "1" ]; then
  ok "notification deduped across reruns"
else bad "notification deduped across reruns (notes=$(notes))"; fi

# 6b. the free pool round-robins, so the SAME drifting seat reports a different
#     answering model each run. Dedup keys on seat+date or NOTIFICATIONS.md stacks.
reset
echo 'nvidia/nemotron-3-super-120b-a12b:free' > "$T/reply_model"
bash "$SH" --seats local-coder >/dev/null
echo 'inclusionai/ling-3.0-flash:free' > "$T/reply_model"
bash "$SH" --seats local-coder >/dev/null
echo 'poolside/laguna-s-2.1:free' > "$T/reply_model"
bash "$SH" --seats local-coder >/dev/null
if [ "$(notes)" = "1" ]; then
  ok "dedup survives a rotating answering model"
else bad "dedup survives a rotating answering model (notes=$(notes), expected 1)"; fi

# 7. unknown seat is an argument error, not a silent pass
reset; echo 'x' > "$T/reply_model"
out=$(bash "$SH" --seats does-not-exist 2>&1); rc=$?
if [ "$rc" = "2" ] && echo "$out" | grep -q 'unknown seat'; then
  ok "unknown seat → exit 2"
else bad "unknown seat → exit 2 (rc=$rc)"; echo "$out"; fi

# 8. THE 8k-CAP BUG (2026-07-29): a seat answers a 1-token probe from its own
#    upstream, then a fallback covers it at real context size. Stage 1 alone
#    reported this as healthy every day while the seat served nothing.
reset; echo 'zai-glm-4.7' > "$T/reply_model"
echo 'gemini-3.1-flash-lite' > "$T/reply_model_big"
out=$(bash "$SH" --seats glm-coder); rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q 'CTXFAIL' && [ "$(notes)" = "1" ]; then
  ok "ok at 1 token but drifts at context size → CTXFAIL"
else bad "CTXFAIL on drift (rc=$rc, notes=$(notes))"; echo "$out"; fi

# 9. the other shape of the same bug: the upstream rejects outright
#    ("Current length is 30009 while limit is 8192") instead of falling back.
reset; echo 'zai-glm-4.7' > "$T/reply_model"; echo 400 > "$T/reply_status_big"
out=$(bash "$SH" --seats glm-coder); rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q 'CTXFAIL' && [ "$(notes)" = "1" ]; then
  ok "context-length rejection at size → CTXFAIL"
else bad "CTXFAIL on error (rc=$rc, notes=$(notes))"; echo "$out"; fi

# 10. --no-ctx restores the old stage-1-only behaviour (and must not notify)
reset; echo 'zai-glm-4.7' > "$T/reply_model"
echo 'gemini-3.1-flash-lite' > "$T/reply_model_big"
out=$(bash "$SH" --seats glm-coder --no-ctx); rc=$?
if [ "$rc" = "0" ] && echo "$out" | grep -q '^  ok ' && [ "$(notes)" = "0" ]; then
  ok "--no-ctx skips stage 2"
else bad "--no-ctx skips stage 2 (rc=$rc, notes=$(notes))"; echo "$out"; fi

# 11. a seat healthy at BOTH sizes stays ok and stays silent
reset; echo 'mistral-large-latest' > "$T/reply_model"
out=$(bash "$SH" --seats local-coder); rc=$?
if [ "$rc" = "0" ] && echo "$out" | grep -q 'tok ok' && [ "$(notes)" = "0" ]; then
  ok "healthy at both sizes → ok, no false positive"
else bad "healthy at both sizes (rc=$rc, notes=$(notes))"; echo "$out"; fi

# 12. --ctx-tokens must reject junk rather than silently probing at 0
out=$(bash "$SH" --seats local-coder --ctx-tokens abc 2>&1); rc=$?
if [ "$rc" = "2" ]; then
  ok "--ctx-tokens rejects a non-integer"
else bad "--ctx-tokens rejects a non-integer (rc=$rc)"; echo "$out"; fi

# --- per-seat context ceiling (2026-08-14) --------------------------------
# free-brain is a documented small-request lane. Probing it at production size
# guaranteed a daily CTXFAIL and made the health daemon read as permanently
# broken. It must be probed at its own ceiling instead — and the ceiling must
# never RAISE a seat above the run's --ctx-tokens.

# 13. a restricted seat is probed at its ceiling, not at production size
reset; echo 'gpt-oss-120b' > "$T/reply_model"
out=$(bash "$SH" --seats free-brain --ctx-tokens 75000); rc=$?
mb=$(maxbody)
# 20,000 tokens of filler is ~88 KB; 75,000 would be ~330 KB.
if [ "$rc" = "0" ] && echo "$out" | grep -q 'small-request lane' \
   && [ "$mb" -gt 20000 ] && [ "$mb" -lt 200000 ]; then
  ok "restricted seat probed at its ceiling, not production size (body=${mb}B)"
else bad "per-seat ceiling (rc=$rc, body=${mb}B)"; echo "$out"; fi

# 14. the ceiling is a MAX, never a floor — a smaller --ctx-tokens still wins
reset; echo 'gpt-oss-120b' > "$T/reply_model"
out=$(bash "$SH" --seats free-brain --ctx-tokens 8000); rc=$?
mb=$(maxbody)
if [ "$rc" = "0" ] && ! echo "$out" | grep -q 'small-request lane' \
   && [ "$mb" -lt 60000 ]; then
  ok "ceiling never raises a seat above --ctx-tokens (body=${mb}B)"
else bad "ceiling is a max not a floor (rc=$rc, body=${mb}B)"; echo "$out"; fi

# 15. a restricted seat that fails its OWN ceiling is still a real finding,
#     and must not quote the production median at the reader
reset; echo 'gpt-oss-120b' > "$T/reply_model"; echo 429 > "$T/reply_status_big"
out=$(bash "$SH" --seats free-brain); rc=$?
if [ "$rc" = "1" ] && echo "$out" | grep -q 'CTXFAIL' && [ "$(notes)" = "1" ] \
   && grep -q 'restricted to small requests' "$T/sergehome/NOTIFICATIONS.md" \
   && ! grep -q '74,700' "$T/sergehome/NOTIFICATIONS.md"; then
  ok "capped seat failing its own ceiling → CTXFAIL with the right consequence"
else bad "capped-seat CTXFAIL wording (rc=$rc, notes=$(notes))"; echo "$out"; fi

# --- exit-code contract (2026-08-14) --------------------------------------
# A finding (exit 1) and a broken checker (exit 3) must not look alike: the
# systemd unit treats 1 as success so that `failed` means the checker itself
# died. Conflating them is what made a routine CTXFAIL read as a dead daemon.

# 16. an unreadable config is a CHECKER failure, not a finding
reset
BADHOME="$T/badhome"; mkdir -p "$BADHOME/monitor"
printf 'model_list: [oops\n' > "$BADHOME/litellm.yaml"
out=$(SERGE_HOME="$BADHOME" bash "$SH" --seats local-coder 2>&1); rc=$?
if [ "$rc" = "3" ]; then
  ok "unparseable litellm.yaml → exit 3 (checker broke), not 1"
else bad "unparseable config → exit 3 (rc=$rc)"; echo "$out"; fi

# 17. a missing config is likewise a checker failure
out=$(SERGE_HOME="$T/nonexistent-home" bash "$SH" --seats local-coder 2>&1); rc=$?
if [ "$rc" = "3" ]; then
  ok "missing litellm.yaml → exit 3 (checker broke), not 1"
else bad "missing config → exit 3 (rc=$rc)"; echo "$out"; fi

echo "---"; echo "pass=$pass fail=$fail"
[ "$fail" = "0" ]
