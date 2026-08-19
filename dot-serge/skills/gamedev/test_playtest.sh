#!/usr/bin/env bash
# Regression test for playtest.mjs — proves the harness CATCHES broken games.
# A verifier that never fails is theater; this is the negative control that keeps it honest.
# Each fixture below is broken in exactly one way and must be caught by its matching check.
#   ./test_playtest.sh   → exit 0 = harness trustworthy
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
n=0; fail=0
ck() { n=$((n+1)); if [ "$1" = "$2" ]; then echo "✓ $3"; else fail=$((fail+1)); echo "✗ $3 (want exit $1, got $2)"; fi; }

cat > "$TMP/crash.mjs" <<'EOF'
export const INPUTS = ['a','b']
export function createGame(){ return { n:0 } }
export function step(s){ s.n++; if (s.n > 300) throw new Error('boom'); return s }
EOF
cat > "$TMP/nan.mjs" <<'EOF'
export const INPUTS = ['a','b']
export function createGame(){ return { x:0, n:0 } }
export function step(s){ s.n++; if (s.n > 100) s.x = s.x/0 - s.x/0; return s }
EOF
cat > "$TMP/deaf.mjs" <<'EOF'
export const INPUTS = ['a','b']
export function createGame(){ return { n:0 } }
export function step(s){ return s }
EOF
cat > "$TMP/nondet.mjs" <<'EOF'
export const INPUTS = ['a','b']
export function createGame(){ return { x:0 } }
export function step(s){ s.x += Math.random(); return s }
EOF

for b in crash nan deaf nondet; do
  node "$DIR/playtest.mjs" "$TMP/$b.mjs" --seeds 2 --frames 600 >/dev/null 2>&1
  ck 1 $? "catches broken game: $b"
done

node "$DIR/playtest.mjs" "$DIR/templates/deterministic-core/game.mjs" --seeds 3 --frames 800 >/dev/null 2>&1
ck 0 $? "passes the known-good template game"

echo ""
[ $fail -eq 0 ] && echo "✓ ALL $n PASS — playtest harness is trustworthy" || echo "✗ $fail/$n FAILED"
exit $((fail == 0 ? 0 : 1))
