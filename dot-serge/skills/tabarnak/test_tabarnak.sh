#!/usr/bin/env bash
# Tests for tabarnak.sh — serge is stubbed (TABARNAK_SERGE_BIN), so this is $0 and
# deterministic: it tests the LOOP's own logic (story picking, the runner-owned
# gate, fail caps, stop file, loud config errors), not any model.
set -uo pipefail
TABARNAK="$(cd "$(dirname "$0")" && pwd)/tabarnak.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# Stub serge: in "build" mode it implements the story by touching the file the
# prompt names (out<N>.txt); in "noop" mode it does nothing (a failing build).
cat > "$T/serge-stub" <<'EOF'
#!/usr/bin/env bash
prompt="${!#}"
if [ "${STUB_MODE:-build}" = "build" ]; then
  f=$(printf '%s' "$prompt" | grep -oE 'out[0-9]+\.txt' | head -1)
  [ -n "$f" ] && touch "$f"
fi
exit 0
EOF
chmod +x "$T/serge-stub"
export TABARNAK_SERGE_BIN="$T/serge-stub" TABARNAK_TIMEOUT=30

mkprd() { cat > "$1" <<'EOF'
{ "stories": [
  { "id": "s1", "priority": 1, "story": "create out1.txt", "acceptance": "out1.txt exists", "test": "[ -f out1.txt ]", "passes": false },
  { "id": "s2", "priority": 2, "story": "create out2.txt", "acceptance": "out2.txt exists", "test": "[ -f out2.txt ]", "passes": false }
] }
EOF
}

# 1. malformed prd → loud config error
mkdir -p "$T/c1" && echo '{"stories": []}' > "$T/c1/prd.json"
out=$(bash "$TABARNAK" --prd prd.json --dir "$T/c1" 2>&1; echo "rc=$?")
if printf '%s' "$out" | grep -q "rc=1" && printf '%s' "$out" | grep -q "malformed"; then
  ok "empty stories → loud config error"
else bad "malformed prd not rejected ($out)"; fi

# 2. story without a test command → refuses to run it
mkdir -p "$T/c2" && echo '{"stories":[{"id":"x","priority":1,"story":"vibes","acceptance":"","test":"","passes":false}]}' > "$T/c2/prd.json"
out=$(bash "$TABARNAK" --prd prd.json --dir "$T/c2" 2>&1; echo "rc=$?")
if printf '%s' "$out" | grep -q "rc=1" && printf '%s' "$out" | grep -q "ungated"; then
  ok "ungated story refused"
else bad "ungated story ran ($out)"; fi

# 3. happy path: both stories built in priority order → COMPLETE, passes=true, commits, progress
mkdir -p "$T/c3" && cd "$T/c3" && git init -q . \
  && git config user.email tabarnak@test.local && git config user.name tabarnak-test \
  && git commit -q --allow-empty -m init && mkprd prd.json
out=$(bash "$TABARNAK" --prd prd.json --dir "$T/c3" --max 5 2>&1; echo "rc=$?")
both=$(python3 -c "import json;d=json.load(open('$T/c3/prd.json'));print(all(s['passes'] for s in d['stories']))")
commits=$(cd "$T/c3" && git log --oneline | grep -c "tabarnak: story" || true)
order=$(printf '%s' "$out" | grep -oE "story s[12] —" | head -1)
if printf '%s' "$out" | grep -q "COMPLETE" && printf '%s' "$out" | grep -q "rc=0" \
   && [ "$both" = "True" ] && [ "$commits" = "2" ] && [ "$order" = "story s1 —" ] \
   && grep -q "PASSED its gate" "$T/c3/progress.txt"; then
  ok "happy path: priority order, gates passed, 2 commits, COMPLETE"
else bad "happy path broke (rc/out=$(printf '%s' "$out" | tail -2), both=$both commits=$commits order=$order)"; fi

# 4. failing story → same-fail cap stops LOUDLY with rc=3
mkdir -p "$T/c4" && cd "$T/c4" && mkprd prd.json
out=$(STUB_MODE=noop bash "$TABARNAK" --prd prd.json --dir "$T/c4" --max 9 --same-fail-cap 3 2>&1; echo "rc=$?")
tries=$(printf '%s' "$out" | grep -c "still failing" || true)
if printf '%s' "$out" | grep -q "rc=3" && printf '%s' "$out" | grep -q "3 times in a row" && [ "$tries" = "3" ]; then
  ok "same-story fail cap: 3 tries then loud stop"
else bad "fail cap broke (tries=$tries out=$(printf '%s' "$out" | tail -2))"; fi

# 5. STOP file honored before any work
mkdir -p "$T/c5" && cd "$T/c5" && mkprd prd.json && touch TABARNAK.STOP
out=$(bash "$TABARNAK" --prd prd.json --dir "$T/c5" 2>&1; echo "rc=$?")
if printf '%s' "$out" | grep -q "rc=3" && printf '%s' "$out" | grep -q "TABARNAK.STOP"; then
  ok "TABARNAK.STOP → graceful stop"
else bad "STOP file ignored ($out)"; fi

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — tabarnak loop trustworthy"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
