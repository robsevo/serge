#!/usr/bin/env bash
# test-url-verify.sh — url-verify-on-stop.sh: does it catch fabricated links
# WITHOUT blocking on legitimate ones?
#
# The false-positive cases (3-9) matter more than the true-positive one: a check
# that argues about working URLs would be retired within a day. Cases 4-6 in
# particular encode the "never trust anything but a hard 404" rule.
#
# Network-dependent by design — it probes real hosts, because the thing under test
# IS the probe. Offline, curl fails and every verdict degrades to "ok" (fail-open),
# so the true-positive cases would report a spurious FAIL; that is the correct
# trade for a checker that must never wedge the stop chain.

set -uo pipefail
SH="${SERGE_HOME:-$HOME/.serge}"
HOOK="$SH/url-verify-on-stop.sh"
pass=0; fail=0

# Isolated cache + loop-guard state so a previous run can't mask a regression.
export TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

run() {   # run <session-id> <final-text> ; echoes hook stdout
  local sid="$1" text="$2"
  python3 -c '
import json,sys
print(json.dumps({"session_id":sys.argv[1],"last_assistant_message":sys.argv[2],
                  "transcript_path":sys.argv[3]}))' "$sid" "$text" "${3:-}" \
    | bash "$HOOK" 2>/dev/null
}

check() {  # check <name> <expect: block|pass> <session-id> <text> [transcript]
  local name="$1" expect="$2" sid="$3" text="$4" tx="${5:-}"
  local out; out="$(run "$sid" "$text" "$tx")"
  local got="pass"
  case "$out" in *'"block"'*) got="block" ;; esac
  if [ "$got" = "$expect" ]; then
    printf '  PASS  %s\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$name" "$expect" "$got"
    [ -n "$out" ] && printf '        out: %.160s\n' "$out"
    fail=$((fail+1))
  fi
}

echo "== url-verify-on-stop.sh =="

# 1. THE REGRESSION: the exact fabricated link from 2026-07-29.
check "fabricated github repo (404) blocks" block s1 \
  'Clone it with `git clone https://github.com/serge-ai/serge.git` and build.'

# 2. Invented hostname — DNS never resolves (curl exit 6).
check "nonexistent domain blocks" block s2 \
  'Docs are at https://serge-official-docs-zzz999.com/getting-started'

# 3. Real repo must not block (the same shape as case 1).
check "real github repo passes" pass s3 \
  'Clone it with `git clone https://github.com/anthropics/claude-code.git` and build.'

# 4. 200-but-nonexistent: PyPI serves 200 for unknown projects. The check must
#    NOT block here (it can't tell) — proof that 200 is never read as proof.
check "pypi 200-for-missing passes (no false block)" pass s4 \
  'Install from https://pypi.org/project/definitely-not-a-real-pkg-zzz/'

# 5. Doc placeholders are not fabrication.
check "example.com placeholder passes" pass s5 \
  'Point it at https://example.com/api/v1 once you have a host.'
check "templated URL passes" pass s5b \
  'Use https://github.com/<your-org>/<your-repo>.git as the remote.'

# 6. Local/private hosts are never probed.
check "localhost passes" pass s6 \
  'The dev server is on http://localhost:3000/health'
check "private IP passes" pass s6b \
  'Router UI: http://192.168.1.1/admin'

# 6b. API endpoints 404 on GET and work on POST. Found by the 2026-07-29 codebase
#     sweep: 23 real, in-use endpoints would have been called fabrications.
#     gitlawb's own 404 body says "Use POST /v1/chat/completions".
check "API endpoint 404-on-GET passes (json)" pass s6c \
  'Point OPENAI_BASE_URL at https://opengateway.gitlawb.com/v1 and set the key.'
check "groq API base passes" pass s6d \
  'Set the base URL to https://api.groq.com/openai/v1 for Groq.'

# 6e. `.example` is a RESERVED TLD (RFC 6761) — the house docs placeholder. All
#     seven occurrences in PROG/docs/integrations/ are NXDOMAIN by design.
check ".example reserved TLD passes" pass s6e \
  'Configure the gateway at https://gateway.acme.example/v1 as shown.'

# 6g. API endpoints that serve an HTML error page for GET — exa, together,
#     xiaomimimo, googleapis, opencode-zen. Content-type can't tell these from a
#     missing repo page, so SHAPE exempts them.
check "api.* host w/ HTML 404 passes" pass s6g \
  'Search provider base URL is https://api.exa.ai/search — set EXA_API_KEY.'
check "/v1 path w/ HTML 404 passes" pass s6h \
  'Use https://opencode.ai/zen/v1 with OPENCODE_API_KEY.'
check "googleapis base passes" pass s6i \
  'Gemini lives at https://generativelanguage.googleapis.com/v1beta/openai'

# 6f. A genuinely dead HTML page must still block — proving 6b/6e/6g narrowed the
#     rule rather than gutting it.
#
#     Deliberately NOT a github.com URL. This assertion used one and went flaky:
#     after the 2026-07-29 codebase sweep probed ~85 github URLs, GitHub started
#     answering 429 intermittently, which fail-open (correctly) treats as a pass.
#     Asserting "must block" against a host the suite itself is rate-limited on
#     tests the rate limiter, not the check.
check "dead HTML page still blocks" block s6f \
  'Details in the LiteLLM docs: https://docs.litellm.ai/docs/proxy/openai_compatible_proxy'

# 7. GROUNDING: a dead URL the USER supplied is not serge's fabrication.
tx_user="$TMPDIR/tx_user.jsonl"
python3 -c '
import json,sys
rows=[{"type":"user","message":{"role":"user","content":
        "check https://github.com/serge-ai/serge.git for me"}}]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows))' "$tx_user"
check "user-supplied dead URL passes (grounded)" pass s7 \
  'That repo is not reachable: https://github.com/serge-ai/serge.git' "$tx_user"

# 8. GROUNDING: a dead URL that came back in TOOL OUTPUT is quoted, not invented.
tx_tool="$TMPDIR/tx_tool.jsonl"
python3 -c '
import json,sys
rows=[{"type":"user","message":{"role":"user","content":[
        {"type":"tool_result","content":"remote: https://github.com/serge-ai/serge.git"}]}}]
open(sys.argv[1],"w").write("\n".join(json.dumps(r) for r in rows))' "$tx_tool"
check "tool-output dead URL passes (grounded)" pass s8 \
  'The configured remote is https://github.com/serge-ai/serge.git' "$tx_tool"

# 9. No URLs at all — the overwhelmingly common turn. Must be a silent no-op.
check "no URLs passes" pass s9 \
  'Fixed the parser and reran the suite: 12 passed, 0 failed.'

# 10. Kill switch.
out="$(SERGE_URL_VERIFY=0 run s10 'See https://github.com/serge-ai/serge.git')"
if [ -z "$out" ]; then printf '  PASS  SERGE_URL_VERIFY=0 disables\n'; pass=$((pass+1))
else printf '  FAIL  SERGE_URL_VERIFY=0 disables (got: %.80s)\n' "$out"; fail=$((fail+1)); fi

# 11. Anti-loop: the SAME final text must block at most once per session.
first="$(run s11 'Clone https://github.com/serge-ai/serge.git')"
second="$(run s11 'Clone https://github.com/serge-ai/serge.git')"
if [[ "$first" == *'"block"'* && "$second" != *'"block"'* ]]; then
  printf '  PASS  identical text blocks once, then yields\n'; pass=$((pass+1))
else
  printf '  FAIL  anti-loop guard (first=%.40s second=%.40s)\n' "$first" "$second"; fail=$((fail+1))
fi

# 12. Malformed hook input must never wedge the stop chain.
out="$(printf 'not json at all' | bash "$HOOK" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  printf '  PASS  malformed input exits 0 silently\n'; pass=$((pass+1))
else
  printf '  FAIL  malformed input (rc=%s out=%.60s)\n' "$rc" "$out"; fail=$((fail+1))
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
