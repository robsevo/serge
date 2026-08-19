#!/usr/bin/env bash
# Behaviour tests for algo-gate.sh (PostToolUse) + complexity-directive.sh
# (UserPromptSubmit) — $0, no LLM, no network.
#
# The property that matters most is scoping: the gate must report ONLY what the
# edit touched. A gate that lectures about a file's pre-existing O(n²) every time
# you edit a comment in it gets switched off within a day, and then neither problem
# is being solved. `pre-existing issue outside the edit stays silent` is that test.
#
# Silence assertions are built so they cannot pass for the wrong reason: each one
# uses a payload that is valid in every other respect (real file, real source
# extension, new_string genuinely present on disk), so the ONLY thing that can
# produce silence is the guard under test.
set -uo pipefail

GATE="${SERGE_ALGO_GATE:-$HOME/.serge/algo-gate.sh}"
DIRECTIVE="${SERGE_COMPLEXITY_DIRECTIVE:-$HOME/.serge/complexity-directive.sh}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# payload <file> <new_string> [tool] [session]
payload() {
  python3 -c '
import json, sys
tool = sys.argv[3] if len(sys.argv) > 3 else "Edit"
ti = {"file_path": sys.argv[1]}
if tool == "Write":
    ti["content"] = sys.argv[2]
elif tool == "MultiEdit":
    ti["edits"] = [{"old_string": "", "new_string": sys.argv[2]}]
else:
    ti["old_string"] = ""
    ti["new_string"] = sys.argv[2]
print(json.dumps({"session_id": sys.argv[4] if len(sys.argv) > 4 else "s1",
                  "tool_name": tool, "tool_input": ti}))' "$1" "$2" "${3:-Edit}" "${4:-s1}"
}

# run_gate <payload> -> sets OUT (stderr+stdout) and RC
run_gate() { OUT="$(printf '%s' "$1" | bash "$GATE" 2>&1)"; RC=$?; }

QUAD='export function enrich(orders, users) {
  const out = [];
  for (const o of orders) {
    out.push(users.find((u) => u.id === o.userId));
  }
  return out;
}'
CLEAN='export function total(items) {
  let t = 0;
  for (const x of items) t += x;
  return t;
}'
OFFBYONE='export function sumAll(items) {
  let t = 0;
  for (let i = 0; i <= items.length; i++) t += items[i];
  return t;
}'

echo "── blocking on what the edit wrote ──"
printf '%s\n' "$CLEAN" > "$T/a.ts"; printf '%s\n' "$QUAD" >> "$T/a.ts"
run_gate "$(payload "$T/a.ts" "$QUAD")"
[ "$RC" = "2" ] && ok "new O(n^2) blocks (exit 2)" || bad "new O(n^2) should block, rc=$RC"
printf '%s' "$OUT" | grep -q "O(n²)" && ok "message names the complexity" || bad "no complexity in message"
printf '%s' "$OUT" | grep -q "→" && ok "message carries a concrete fix" || bad "no fix offered"

printf '%s\n' "$CLEAN" > "$T/b.ts"; printf '%s\n' "$OFFBYONE" >> "$T/b.ts"
run_gate "$(payload "$T/b.ts" "$OFFBYONE")"
[ "$RC" = "2" ] && ok "new off-by-one blocks (exit 2)" || bad "off-by-one should block, rc=$RC"

echo
echo "── scoping: you own what you touched ──"
# The QUAD function is ALREADY in the file; this edit adds only clean code.
printf '%s\n' "$QUAD" > "$T/c.ts"; printf '%s\n' "$CLEAN" >> "$T/c.ts"
run_gate "$(payload "$T/c.ts" "$CLEAN")"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then ok "pre-existing issue outside the edit stays silent"
else bad "nagged about untouched code (rc=$RC): ${OUT:0:100}"; fi
# Same file, same gate, now edit the bad part → must fire. Proves the silence above
# was scoping, not an early exit.
run_gate "$(payload "$T/c.ts" "$QUAD" Edit s-scope)"
[ "$RC" = "2" ] && ok "editing the bad part of the SAME file does block" \
                || bad "control failed: gate never fires on this file at all"

echo
echo "── clean code is silent ──"
printf '%s\n' "$CLEAN" > "$T/d.ts"
run_gate "$(payload "$T/d.ts" "$CLEAN")"
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then ok "clean edit → no output, exit 0"
else bad "clean edit produced output (rc=$RC): ${OUT:0:100}"; fi

echo
echo "── repeat handling (no turn-burning loop) ──"
printf '%s\n' "$QUAD" > "$T/e.ts"
run_gate "$(payload "$T/e.ts" "$QUAD" Edit s-rep)"
[ "$RC" = "2" ] && ok "first sighting blocks" || bad "first sighting should block"
run_gate "$(payload "$T/e.ts" "$QUAD" Edit s-rep)"
if [ "$RC" = "0" ] && printf '%s' "$OUT" | grep -q "Still open"; then
  ok "same finding again → advisory, not a second block"
else bad "repeat should downgrade (rc=$RC): ${OUT:0:100}"; fi
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="PostToolUse"; assert d["hookSpecificOutput"]["additionalContext"]' 2>/dev/null; then
  ok "advisory path emits valid PostToolUse additionalContext"
else bad "advisory path emitted malformed JSON: ${OUT:0:120}"; fi

echo
echo "── payload shapes ──"
printf '%s\n' "$QUAD" > "$T/f.ts"
run_gate "$(payload "$T/f.ts" "$QUAD" Write s-w)"
[ "$RC" = "2" ] && ok "Write payload (content) is analysed" || bad "Write not analysed, rc=$RC"
printf '%s\n' "$QUAD" > "$T/g.ts"
run_gate "$(payload "$T/g.ts" "$QUAD" MultiEdit s-m)"
[ "$RC" = "2" ] && ok "MultiEdit payload (edits[]) is analysed" || bad "MultiEdit not analysed, rc=$RC"

echo
echo "── deliberation: derive a better algorithm, don't patch ──"
NAIVE='export function enrich(orders, users) {
  const out = [];
  for (const o of orders) {
    out.push(users.find((u) => u.id === o.userId));
  }
  return out;
}'
# A cache in front of a linear scan: still O(n²) for distinct keys. This is the exact
# "fix" a real serge session produced after being flagged, while declaring it O(n).
PATCHED='export function enrich(orders, users) {
  const cache = new Map();
  const out = [];
  for (const o of orders) {
    let u = cache.get(o.userId);
    if (!u) {
      u = users.find((x) => x.id === o.userId);
      cache.set(o.userId, u);
    }
    out.push(u);
  }
  return out;
}'
REAL='export function enrich(orders, users) {
  const byId = new Map(users.map((u) => [u.id, u]));
  return orders.map((o) => byId.get(o.userId));
}'
printf '%s\n' "$NAIVE" > "$T/dl.ts"
run_gate "$(payload "$T/dl.ts" "$NAIVE" Write s-dl)"
[ "$RC" = "2" ] && ok "naive version blocks" || bad "naive should block, rc=$RC"
printf '%s' "$OUT" | grep -q "derive a better algorithm" \
  && ok "message demands a derivation, not just a fix" || bad "no derivation demanded"
printf '%s' "$OUT" | grep -q "dict/set/Map ONCE" \
  && ok "offers the technique that fits the shape" || bad "no matching technique offered"
printf '%s' "$OUT" | grep -q "1\. n = " \
  && ok "asks for n before the code" || bad "does not ask for n"

printf '%s\n' "$PATCHED" > "$T/dl.ts"
run_gate "$(payload "$T/dl.ts" "$PATCHED" Write s-dl)"
[ "$RC" = "2" ] && ok "a patch that leaves the exponent still blocks" || bad "patch slipped through, rc=$RC"
printf '%s' "$OUT" | grep -q "STILL O(n²) after your last edit" \
  && ok "names the stall: the exponent did not move" || bad "stall not detected: ${OUT:0:120}"

printf '%s\n' "$REAL" > "$T/dl.ts"
run_gate "$(payload "$T/dl.ts" "$REAL" Write s-dl)"
if [ "$RC" = "0" ]; then ok "the real algorithm change clears the gate"
else bad "correct O(n) rewrite still blocked (rc=$RC): ${OUT:0:120}"; fi

echo
echo "── fluff can never block, at any volume ──"
python3 - "$T/bloat.ts" <<'PY'
import sys
L = ["export function huge(n) {"]
for i in range(60):
    L += ["  const unused%d = %d;" % (i, i), "  // set the unused value %d" % i]
L.append("  if (n > 10) {\n    return true;\n  }\n  return false;\n}")
open(sys.argv[1], "w").write("\n".join(L) + "\n")
PY
run_gate "$(payload "$T/bloat.ts" "$(cat "$T/bloat.ts")" Write s-bloat)"
[ "$RC" = "0" ] && ok "60+ removable lines still never blocks" || bad "fluff blocked a turn (rc=$RC)"
printf '%s' "$OUT" | grep -q "removable" && ok "…but is still reported" || bad "large fluff went unreported"

echo
echo "── cross-file: the cost only exists through a helper elsewhere ──"
X="$T/xf"; mkdir -p "$X"
cat > "$X/helper.ts" <<'EOF'
export function lookup(users, id) {
  return users.find((u) => u.id === id);
}
EOF
cat > "$X/noisy.ts" <<'EOF'
export function bad(a, b) {
  for (const x of a) {
    for (const y of b) {
      log(x, y);
    }
  }
}
EOF
XNEW='export function enrich(orders, users) {
  const out = [];
  for (const o of orders) {
    out.push(lookup(users, o.userId));
  }
  return out;
}'
printf 'export function ping() {\n  return "ok";\n}\n%s\n' "$XNEW" > "$X/svc.ts"
run_gate "$(payload "$X/svc.ts" "$XNEW" Edit s-xf)"
if [ "$RC" = "2" ] && printf '%s' "$OUT" | grep -q "calls \`lookup()\`"; then
  ok "resolves a callee defined in a sibling file"
else bad "cross-file cost missed (rc=$RC): ${OUT:0:120}"; fi
# The sibling files are CONTEXT. noisy.ts is genuinely O(n²) but was not edited.
printf '%s' "$OUT" | grep -q "noisy" && bad "reported an unedited context file" \
                                     || ok "context files are never reported"
# A hook must never leak a traceback — the model would read it as a finding.
printf '%s' "$OUT" | grep -qi "traceback" && bad "leaked a Python traceback" \
                                          || ok "no traceback on any path"

echo
echo "── fluff never blocks ──"
FLUFFY='export function check(n) {
  const unusedA = 1;
  const unusedB = 2;
  const unusedC = 3;
  if (n > 10) {
    return true;
  }
  return false;
}'
printf '%s\n' "$FLUFFY" > "$T/h.ts"
run_gate "$(payload "$T/h.ts" "$FLUFFY" Edit s-f)"
if [ "$RC" = "0" ]; then ok "dead weight alone never blocks the turn"
else bad "fluff blocked (rc=$RC): ${OUT:0:100}"; fi
printf '%s' "$OUT" | grep -q "removable" && ok "material dead weight is still reported" \
  || bad "material dead weight went unreported: ${OUT:0:100}"

echo
echo "── fail-open guards ──"
printf '%s\n' "$QUAD" > "$T/i.ts"
P="$(payload "$T/i.ts" "$QUAD" Edit s-guard)"
OUT="$(printf '%s' "$P" | SERGE_ALGO_GATE_DISABLE=1 bash "$GATE" 2>&1)"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] && ok "SERGE_ALGO_GATE_DISABLE=1 → silent" || bad "disable flag ignored"
OUT="$(printf '%s' "$P" | SERGE_EVAL=1 bash "$GATE" 2>&1)"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] && ok "SERGE_EVAL=1 → silent (eval deltas stay attributable)" \
                                || bad "eval guard ignored"
# The same payload without the guards MUST fire, or both checks above are vacuous.
run_gate "$P"
[ "$RC" = "2" ] && ok "control: same payload fires without the guards" \
                || bad "guard tests are vacuous — payload never fires"

printf 'hello\n' > "$T/j.md"
run_gate "$(payload "$T/j.md" "hello")"
[ "$RC" = "0" ] && [ -z "$OUT" ] && ok "non-source file → silent" || bad "non-source not skipped"
run_gate "$(payload "$T/does-not-exist.ts" "$QUAD")"
[ "$RC" = "0" ] && [ -z "$OUT" ] && ok "missing file → silent (fail open)" || bad "missing file not handled"
OUT="$(printf 'not json at all' | bash "$GATE" 2>&1)"; RC=$?
[ "$RC" = "0" ] && [ -z "$OUT" ] && ok "malformed payload → silent (fail open)" || bad "malformed payload not handled"
OUT="$(printf '%s' "$P" | SERGE_ALGO_CHECKER=/nonexistent/x.py bash "$GATE" 2>&1)"; RC=$?
[ "$RC" = "0" ] && ok "missing checker → silent (fail open)" || bad "missing checker not handled"

echo
echo "── directive: fires where it should ──"
drun() { printf '{"prompt":%s}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" | bash "$DIRECTIVE"; }
dfires() { local o; o="$(drun "$2")"; printf '%s' "$o" | grep -q "$3" && ok "$1" || bad "$1 — missed"; }
dquiet() { local o; o="$(drun "$2")"; [ -z "$o" ] && ok "$1 (quiet)" || bad "$1 — fired"; }

dfires "build: endpoint"      "add an endpoint that returns enriched orders"       "COMPLEXITY BUDGET"
dfires "build: for each"      "for each order, look up the customer and attach it" "COMPLEXITY BUDGET"
dfires "cost: slow endpoint"  "the /orders endpoint is slow"                       "COMPLEXITY BUDGET"
dfires "cost: n+1"            "I think there's an n+1 query in the loader"         "COMPLEXITY BUDGET"
dfires "cost: scale"          "will this scale to a million rows?"                 "COMPLEXITY BUDGET"
dfires "names the checker"    "optimize this sorting loop"                         "algo_check.py"
dfires "volume: too much"     "this is way too much code for what it does"         "VOLUME"
dfires "volume: simplify"     "simplify this module"                               "VOLUME"
dfires "volume demands count" "simplify this module"                               "Line counts before and after"

echo
echo "── directive: planning gets DEPTH, not trim-pressure ──"
# Volume discipline is about shipped CODE. A plan or a brainstorm is where the
# expensive decision is made, and a thin plan is how a confident wrong design gets
# built — so the VOLUME class must not fire there, and the budget text must ask for
# detail instead. The trimming happens later, against real code.
dplan() { printf '{"prompt":%s%s}' \
    "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1")" "${2:-}" | bash "$DIRECTIVE"; }
pf() { local o; o="$(dplan "$2" "${4:-}")"; printf '%s' "$o" | grep -q "$3" && ok "$1" || bad "$1 — missed"; }
pn() { local o; o="$(dplan "$2" "${4:-}")"; printf '%s' "$o" | grep -q "$3" && bad "$1 — leaked '$3'" || ok "$1"; }

pf "plan + cost asks for DETAIL"    "plan how we should optimize the slow query loop"     "go into DETAIL"
pf "brainstorm asks for DETAIL"     "brainstorm approaches for the dedupe algorithm"      "go into DETAIL"
pf "tradeoffs asks for DETAIL"      "what are the tradeoffs for indexing the orders loop" "go into DETAIL"
pf "plan MODE from the payload"     "the orders endpoint is slow" "go into DETAIL" ',"permission_mode":"plan"'
pf "says the rule is about CODE"    "plan how to optimize the slow query loop"            "SHIPPED CODE"
pn "planning suppresses VOLUME"     "plan how to simplify this bloated module"            "VOLUME —"
pn "coding turn gets no DETAIL note" "simplify this module, too much code"                "go into DETAIL"
pn "build turn gets no DETAIL note"  "add an endpoint that returns enriched orders"       "go into DETAIL"
pf "coding turn still gets VOLUME"   "simplify this module, too much code"                "VOLUME"

echo
echo "── directive: stays quiet ──"
dquiet "frontend button"  "add a logout button to the header"
dquiet "slow reply"       "sorry for the slow reply this morning"
dquiet "perf review"      "I have a performance review on friday"
dquiet "slash command"    "/sc:analyze the parser"
dquiet "plain question"   "what does this repo do?"
dquiet "acknowledgement"  "thanks!"
o="$(drun "optimize the slow endpoint loop and write a faster handler function")"
[ "$(printf '%s' "$o" | grep -c 'COMPLEXITY BUDGET')" = "1" ] \
  && ok "COST+BUILD emit a single block" || bad "duplicate budget blocks emitted"

echo
echo "════ $pass passed, $fail failed ════"
[ "$fail" -eq 0 ]
