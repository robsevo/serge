#!/usr/bin/env bash
# Tests for curiosity-capture.sh — $0, no LLM, no network.
#
# Runs against a throwaway SERGE_HOME + TMPDIR so it can never write the real
# journal or leave dedupe markers in /tmp.
set -uo pipefail
HOOK="${SERGE_CURIOSITY_SCRIPT:-$HOME/.serge/curiosity-capture.sh}"
REAL_JOURNAL="$HOME/.serge/skills/_learnings/journal.jsonl"
before_real=$(wc -l < "$REAL_JOURNAL" 2>/dev/null || echo 0)

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SERGE_HOME="$T/home" TMPDIR="$T/tmp"
mkdir -p "$SERGE_HOME/skills/_learnings" "$TMPDIR"
J="$SERGE_HOME/skills/_learnings/journal.jsonl"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

run()   { printf '{"transcript_path":"%s","session_id":"s%s"}' "$T/tx" "$RANDOM" | bash "$HOOK"; }
count() { wc -l < "$J" 2>/dev/null || echo 0; }
reset() { : > "$J"; rm -f "$TMPDIR"/serge-curiosity-*; }

echo "── LOOKED-UP: serge went and found out ──"
reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"add rate limiting to the api"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebSearch","input":{"query":"next.js middleware rate limit upstash"}}]}}
EOF
run
[ "$(count)" = 1 ] && ok "a WebSearch turn is journalled" || bad "no entry for a lookup"
grep -q '"kind": "self_learned"' "$J" && ok "kind=self_learned (distinct from user-sourced signals)" || bad "wrong kind"
grep -q "upstash" "$J" && ok "captures the query — the query IS the topic" || bad "query not captured"
grep -q "add rate limiting" "$J" && ok "captures what it was working on" || bad "task context missing"

reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"read the docs"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{"url":"https://vercel.com/docs/edge-config"}}]}}
EOF
run
[ "$(count)" = 1 ] && ok "WebFetch counts as a lookup too" || bad "WebFetch ignored"

echo
echo "── quiet when nothing was learned (this must not become a tax) ──"
reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"rename the variable"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/a.ts"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok","is_error":false}]}}
EOF
run
[ "$(count)" = 0 ] && ok "an ordinary edit turn journals nothing" || bad "fired on a plain turn"

reset; cat > "$T/tx" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebSearch","input":{"query":"x"}}]}}
EOF
run
[ "$(count)" = 0 ] && ok "no human turn ⇒ nothing captured" || bad "captured without a user request"

echo
echo "── HARD-WAY: repeated failure then success ──"
reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"fix the failing build"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"Bash","input":{"command":"npm run build"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a1","content":"err","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a2","name":"Bash","input":{"command":"npm run build"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a2","content":"err","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a3","name":"Bash","input":{"command":"npm run build"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a3","content":"done","is_error":false}]}}
EOF
run
grep -q "Solved the hard way" "$J" && ok "2 fails then success is a lesson" || bad "hard-way signal missed"

# Still failing is not a lesson yet — there is nothing to record.
reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"fix the build"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"npm run build"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"err","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b2","name":"Bash","input":{"command":"npm run build"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b2","content":"err","is_error":true}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b3","name":"Bash","input":{"command":"npm run build"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b3","content":"err","is_error":true}]}}
EOF
run
[ "$(count)" = 0 ] && ok "failures with no success are not journalled" || bad "recorded an unsolved failure"

echo
echo "── noise discipline ──"
reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"research vercel edge config"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"WebSearch","input":{"query":"vercel edge config"}},{"type":"tool_use","id":"s2","name":"WebSearch","input":{"query":"Vercel Edge Config"}}]}}
EOF
run
python3 -c "
import json,sys
t=json.loads(open('$J').read().strip().split(chr(10))[0])['text'].lower()
sys.exit(0 if t.count('vercel edge config')==2 else 1)" \
  && ok "case-insensitive dedupe of repeat queries" || bad "duplicate queries not deduped"

# Stop hooks re-fire when a gate blocks and the turn continues.
reset; cat > "$T/tx" <<'EOF'
{"type":"user","message":{"content":"add caching"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"WebSearch","input":{"query":"swr cache headers"}}]}}
EOF
run; run; run
[ "$(count)" = 1 ] && ok "same turn journalled ONCE across repeated stop fires" || bad "duplicated on re-fire ($(count))"

echo
echo "── safety ──"
reset
o=$(SERGE_CURIOSITY_DISABLE=1 run); [ "$(count)" = 0 ] && ok "SERGE_CURIOSITY_DISABLE=1 → inert" || bad "off-switch ignored"
o=$(printf '{"bogus":1}' | bash "$HOOK" 2>&1); rc=$?
{ [ "$rc" = 0 ] && [ -z "$o" ]; } && ok "malformed payload → fails open" || bad "malformed payload rc=$rc"
o=$(printf '{"transcript_path":"/nope/missing"}' | bash "$HOOK" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "missing transcript → fails open" || bad "crashed on missing transcript"
o=$(run); [ -z "$o" ] && ok "never speaks to the model (capture only)" || bad "emitted output"

after_real=$(wc -l < "$REAL_JOURNAL" 2>/dev/null || echo 0)
[ "$before_real" = "$after_real" ] && ok "suite never wrote the real journal" || bad "polluted production"

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL $pass PASS — curiosity capture"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
