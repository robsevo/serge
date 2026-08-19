#!/usr/bin/env bash
# Known-answer tests for algo_check.py — $0, no LLM, no network.
#
# Every positive case is a program whose complexity or defect is known by hand
# (bubble sort IS O(n²); naive fib IS O(2^n)). Every NEGATIVE control is correct
# code that an over-eager rule would flag — and each one here corresponds to a real
# false positive this checker produced against 594k lines of production TypeScript
# before it was tightened. The negatives are the point: a checker that flags
# everything is a checker nobody leaves switched on.
set -uo pipefail

CHK="${SERGE_ALGO_CHECKER:-$HOME/.serge/skills/complexity/algo_check.py}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# has <label> <file> <mode> <min-sev> <grep-pattern>
has() {
  local out; out="$(python3 "$CHK" "$3" "$T/$2" --min-sev "$4" 2>&1)"
  if printf '%s' "$out" | grep -qE "$5"; then ok "$1"
  else bad "$1 — expected /$5/, got: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"; fi
}
# hasnt <label> <file> <mode> <min-sev> <grep-pattern>
hasnt() {
  local out; out="$(python3 "$CHK" "$3" "$T/$2" --min-sev "$4" 2>&1)"
  if printf '%s' "$out" | grep -qE "$5"; then
    bad "$1 — FALSE POSITIVE: $(printf '%s' "$out" | grep -E "$5" | head -1)"
  else ok "$1"; fi
}

cat > "$T/cost.py" <<'EOF'
def bubble(items):
    for i in range(len(items)):
        for j in range(len(items) - 1):
            if items[j] > items[j + 1]:
                items[j] = items[j + 1]


def bsearch(items, target):
    lo, hi = 0, len(items) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if items[mid] == target:
            return mid
        if items[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1


def two_sum(nums, target):
    seen = {}
    for i, v in enumerate(nums):
        if target - v in seen:
            return i
        seen[v] = i


def fib(n):
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def load(ids, cursor):
    return [cursor.execute("select 1", i) for i in ids]


def small(rows):
    for r in rows:
        for k in range(3):
            print(r, k)


def comp_n_plus_one(ids, cursor):
    return [cursor.execute("q", i) for i in ids]


def comp_cross(a, b):
    return [(x, y) for x in a for y in b]


def comp_fine(rows):
    return [r.name for r in rows]


def comp_fixed(rows):
    return [(r, k) for r in rows for k in (1, 2, 3)]
EOF

echo "── Python: cost ──"
has   "bubble sort is O(n^2)"        cost.py bigo high  'bubble .*O\(n²\)'
has   "naive fib is exponential"     cost.py bigo high  'fib .*O\(2\^n\)'
has   "query in a loop is N+1"       cost.py bigo high  'N\+1'
has   "N+1 inside a comprehension"   cost.py bigo high  'comp_n_plus_one|line 3[0-9]'
has   "two-generator comp is O(n^2)" cost.py bigo high  'comp_cross — est\. O\(n²\)'
hasnt "binary search is not n^2"     cost.py bigo high  'bsearch'
hasnt "dict lookup is not a scan"    cost.py bigo high  'two_sum'
hasnt "constant inner bound not n^2" cost.py bigo high  'small'
hasnt "plain comprehension is O(n)"  cost.py bigo high  'comp_fine'
hasnt "literal inner generator ok"   cost.py bigo high  'comp_fixed'

cat > "$T/bounds.py" <<'EOF'
MAX_RETRIES = 5


def over_end(items):
    for i in range(len(items) + 1):
        print(items[i])


def pairwise(items):
    for i in range(len(items)):
        print(items[i] + items[i + 1])


def spin(queue):
    n = len(queue)
    while n > 0:
        print(queue)


def drain(queue):
    while queue:
        queue.pop()


def should_retry(a):
    return a > MAX_RETRIES


def guard(a):
    if a >= MAX_RETRIES:
        raise RuntimeError("no")


def prune(items):
    for x in items:
        if x is None:
            items.remove(x)


def collect(acc=[]):
    acc.append(1)


def numbered(rows):
    for i, r in enumerate(rows, 1):
        print(rows[i], r)


def swallow(p):
    try:
        open(p)
    except Exception:
        pass
EOF

echo
echo "── Python: bounds ──"
has   "range(len+1) indexing"        bounds.py bounds certain 'range\(len\(items\) \+ 1\)'
has   "items[i+1] past the end"      bounds.py bounds high    'i \+ 1.*final step'
has   "while that never advances"    bounds.py bounds certain 'spin|never updates n'
has   "mutation during iteration"    bounds.py bounds certain 'mutates the list being iterated'
has   "mutable default argument"     bounds.py bounds certain 'mutable default'
has   "enumerate(x,1) then index"    bounds.py bounds certain 'enumerate\(rows, 1\)'
has   "except: pass swallows"        bounds.py bounds high    'swallows the failure'
has   "> vs >= on the same pair"     bounds.py bounds high    'boundary inconsistency'
hasnt "pop() in the test advances"   bounds.py bounds certain 'while queue|drain'

cat > "$T/cost.ts" <<'EOF'
export function enrich(orders, users) {
  const out = [];
  for (const o of orders) {
    out.push({ ...o, user: users.find((u) => u.id === o.userId) });
  }
  return out;
}

export function fastEnrich(orders, users) {
  const byId = new Map(users.map((u) => [u.id, u]));
  return orders.map((o) => ({ ...o, user: byId.get(o.userId) }));
}

export function accumulate(rows) {
  return rows.reduce((acc, r) => [...acc, r * 2], []);
}

export async function loadAll(ids) {
  const out = [];
  for (const id of ids) {
    out.push(await db.findOne({ id }));
  }
  return out;
}
EOF

echo
echo "── JS/TS: cost ──"
has   "nested find is O(n^2)"        cost.ts bigo high 'enrich — est\. O\(n²\)'
has   "reduce spread is O(n^2)"      cost.ts bigo high 'accumulate — est\. O\(n²\)'
has   "await in a loop is N+1"       cost.ts bigo high 'N\+1'
hasnt "Map-indexed version is O(n)"  cost.ts bigo high 'fastEnrich'
hasnt "element spread is not O(n^2)" cost.ts bigo high 'fastEnrich — est'

cat > "$T/bounds.ts" <<'EOF'
const LIMIT = 100;

export function sumAll(items) {
  let t = 0;
  for (let i = 0; i <= items.length; i++) t += items[i];
  return t;
}

export function sweep(str) {
  for (let i = 0; i <= str.length; i++) {
    const c = str[i];
    if (c === undefined) break;
  }
}

export function window(line, keyLen) {
  for (let i = 0; i <= line.length - keyLen; i++) {
    check(line[i]);
  }
}

export function countdown(n) {
  for (let i = n; i >= 0; i++) log(i);
}

export function mid(items, lo, hi) {
  const m = (lo + hi) / 2;
  return items[m];
}

export function isOver(n) {
  if (n > LIMIT) return true;
  return false;
}

export function assertUnder(n) {
  if (n >= LIMIT) throw new Error("over");
}
EOF

# Negative controls live in their OWN file. Sharing a file with the positives let a
# broad grep pattern be satisfied by a neighbouring TRUE finding — the assertion
# passed for the wrong reason and would never have gone red. Alone in a file, the
# rule is absolute: ANY finding here is a false positive.
cat > "$T/bounds_ok.ts" <<'EOF'
export function sweep(str) {
  for (let i = 0; i <= str.length; i++) {
    const c = str[i];
    if (c === undefined) break;
  }
}

export function window(line, keyLen) {
  for (let i = 0; i <= line.length - keyLen; i++) {
    check(line[i]);
  }
}

export function scan(messages, from, dir) {
  for (let i = from; i >= 0 && i < messages.length; i += dir) {
    if (messages[i]) return i;
  }
}

export function drain(queue) {
  while (queue.length > 0) {
    const item = queue.shift();
    handle(item);
  }
}

export function advanceAll(L) {
  while (L.i < L.len) {
    advance(L);
  }
}

export function readAll(gen) {
  let e;
  do {
    e = gen.next();
  } while (!e.done);
}

export function walk(re, s) {
  let n = 0;
  while (re.exec(s) !== null) n++;
  return n;
}

export function eachOf(items) {
  for (const x of items) {
    handle(x);
  }
}

export function pairsSafely(items) {
  for (let i = 0; i < items.length - 1; i++) {
    handle(items[i], items[i + 1]);
  }
}
EOF

echo
echo "── JS/TS: bounds ──"
has   "i <= arr.length overruns"     bounds.ts bounds certain 'i <= items.length'
has   "countdown never terminates"   bounds.ts bounds certain 'counts DOWN but the step counts UP'
has   "float midpoint as an index"   bounds.ts bounds certain 'yields a float'
has   "> vs >= on the same pair"     bounds.ts bounds high    'boundary inconsistency'

echo "   (negative controls — correct code, alone in its own file)"
hasnt "guarded sentinel sweep is ok" bounds_ok.ts bounds certain 'str.length'
hasnt "sliding window bound is ok"   bounds_ok.ts bounds certain 'line.length'
hasnt "bidirectional scan is ok"     bounds_ok.ts bounds certain 'counts (UP|DOWN)'
hasnt "shift() advances the loop"    bounds_ok.ts bounds certain 'queue'
hasnt "callee mutation advances"     bounds_ok.ts bounds certain 'L\.i'
hasnt "do-while body is not next {}" bounds_ok.ts bounds certain 'done'
hasnt "exec() in the test advances"  bounds_ok.ts bounds certain 'exec'
hasnt "for...of has no direction"    bounds_ok.ts bounds certain 'eachOf'
out="$(python3 "$CHK" all "$T/bounds_ok.ts" --min-sev certain 2>&1)"
if printf '%s' "$out" | grep -q "^clean"; then ok "ALL correct code → zero certain findings"
else bad "correct-code file produced findings: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi

cat > "$T/fluff.ts" <<'EOF'
export function isBig(n) {
  if (n > 10) {
    return true;
  }
  return false;
}

export function load(p) {
  try {
    return read(p);
  } catch (e) {
    throw e;
  }
}

export function calc(a, b) {
  const unusedTotal = a * b;
  // update the user cache
  updateUserCache();
  return a + b;
}
EOF

echo
echo "── fluff ──"
has "if/return true/false"        fluff.ts fluff medium 'just the condition'
has "rethrow-only catch"          fluff.ts fluff medium 'rethrows unchanged'
has "declared and never used"     fluff.ts fluff medium 'unusedTotal.*never used'
has "comment restates the code"   fluff.ts fluff medium 'restates the next line'
has "reports removable lines"     fluff.ts fluff medium 'removable'

echo
echo "── interprocedural: a linear helper called inside a loop ──"
# Neither function is quadratic on its own. Only the CALL makes it O(n²) — the
# blind spot that made "clean" a wrong answer before this pass existed.
cat > "$T/inter.ts" <<'EOF'
function findUser(users, id) {
  return users.find((u) => u.id === id);
}

export function enrichAll(orders, users) {
  const out = [];
  for (const o of orders) {
    out.push(findUser(users, o.userId));
  }
  return out;
}

export function callOnce(users) {
  return findUser(users, "x");
}
EOF
cat > "$T/inter.py" <<'EOF'
def find_user(users, uid):
    for u in users:
        if u["id"] == uid:
            return u


def enrich_all(orders, users):
    return [find_user(users, o["uid"]) for o in orders]


def call_once(users):
    return find_user(users, "x")
EOF
has   "JS: helper in a loop is O(n^2)"  inter.ts bigo high 'enrichAll — est\. O\(n²\).*calls .findUser'
has   "PY: helper in a comprehension"   inter.py bigo high 'enrich_all — est\. O\(n²\).*calls .find_user'
hasnt "JS: calling it ONCE is not n^2"  inter.ts bigo high 'callOnce'
hasnt "PY: calling it ONCE is not n^2"  inter.py bigo high 'call_once'
# Cross-FILE: the same helper, split across two files, resolves only when both are
# analysed together — and must NOT resolve to a same-named function elsewhere.
cat > "$T/helper2.py" <<'EOF'
def lookup2(users, uid):
    for u in users:
        if u["id"] == uid:
            return u
EOF
cat > "$T/caller2.py" <<'EOF'
def enrich2(orders, users):
    out = []
    for o in orders:
        out.append(lookup2(users, o["uid"]))
    return out
EOF
out="$(python3 "$CHK" bigo "$T/caller2.py" --no-context --min-sev high 2>&1)"
printf '%s' "$out" | grep -q "clean" && ok "cross-file: file-local alone → no invented verdict" \
  || bad "claimed a complexity it could not resolve: ${out:0:90}"
out="$(python3 "$CHK" bigo "$T/caller2.py" "$T/helper2.py" --min-sev high 2>&1)"
printf '%s' "$out" | grep -q 'enrich2 — est\. O(n²)' && ok "cross-file: resolves when both are given" \
  || bad "cross-file propagation missed: ${out:0:90}"
# The auto-context path is what a model actually hits: it runs the checker on ONE
# file and never thinks to name the siblings. Live-observed failure — serge did
# exactly this, got "clean", and reported O(n) for code that was O(n²).
out="$(python3 "$CHK" bigo "$T/caller2.py" --min-sev high 2>&1)"
printf '%s' "$out" | grep -q 'enrich2 — est\. O(n²)' \
  && ok "cross-file: siblings auto-load for a single named file" \
  || bad "auto-context did not resolve the sibling: ${out:0:90}"
# Auto-context must still only REPORT the named file.
printf '%s' "$out" | grep -q "noisy2\|helper2" \
  && bad "auto-context reported an unnamed file" || ok "auto-context reports only the named file"
# --lines must not let a CONTEXT file's own findings leak in as if they were the target's
cat > "$T/noisy2.py" <<'EOF'
def noisy(a, b):
    for x in a:
        for y in b:
            print(x, y)
EOF
out="$(python3 "$CHK" bigo "$T/caller2.py" "$T/noisy2.py" --lines 1-10 --min-sev high 2>&1)"
printf '%s' "$out" | grep -q "noisy" && bad "context file leaked its own findings through --lines" \
  || ok "--lines keeps context files as context only"

echo
echo "── the evidence chain must be auditable ──"
# Sibling loops are ADDITIVE (max wins). Joining them with `×` asserted a derivation
# the verdict does not have — seen in the wild as a 7-loop chain behind an O(n³)
# verdict, which is exactly the thing a reader checks and then stops trusting.
cat > "$T/sib.ts" <<'EOF'
export function f(a, b, c) {
  for (const x of a) {
    for (const y of b) { use(x, y); }
    for (const z of c) { use(x, z); }
  }
}
EOF
out="$(python3 "$CHK" bigo "$T/sib.ts" --min-sev high --no-context 2>&1)"
n="$(printf '%s' "$out" | head -1 | grep -o '×' | wc -l)"
[ "$n" = "1" ] && ok "sibling loops are not multiplied into the chain" \
  || bad "chain multiplies siblings ($n '×' for an O(n²) verdict): $(printf '%s' "$out" | head -1)"
printf '%s' "$out" | grep -q 'est\. O(n²)' && ok "…and the verdict itself stays correct" \
  || bad "verdict changed: $(printf '%s' "$out" | head -1)"

echo
echo "── a 2-D table fill is at its lower bound, not a defect ──"
cat > "$T/lev.ts" <<'EOF'
export function levenshtein(s, t) {
  const dp = [];
  for (let i = 0; i <= s.length; i++) {
    for (let j = 0; j <= t.length; j++) {
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1);
    }
  }
  return dp[s.length][t.length];
}
EOF
cat > "$T/lev.py" <<'EOF'
def levenshtein(s, t):
    dp = [[0] * (len(t) + 1) for _ in range(len(s) + 1)]
    for i in range(1, len(s) + 1):
        for j in range(1, len(t) + 1):
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1)
    return dp[len(s)][len(t)]
EOF
for f in lev.ts lev.py; do
  out="$(python3 "$CHK" bigo "$T/$f" --min-sev medium --no-context 2>&1)"
  printf '%s' "$out" | grep -q "lower bound" && ok "$f: names the lower bound" \
    || bad "$f: no lower-bound note: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  printf '%s' "$out" | grep -q "pre-index the inner collection" \
    && bad "$f: still gives nonsense pre-index advice" || ok "$f: no bogus pre-index advice"
  python3 "$CHK" bigo "$T/$f" --min-sev high --no-context --quiet >/dev/null 2>&1
  [ $? -eq 0 ] && ok "$f: does not block the edit gate (medium, not high)" \
    || bad "$f: a correct DP table would block a turn"
done

echo
echo "── fixed-size collections are not n ──"
cat > "$T/consts.ts" <<'EOF'
const MODES = ["fast", "slow", "auto"];
export function applyAll(rows) {
  for (const r of rows) {
    for (const m of MODES) {
      emit(r, m);
    }
  }
}
EOF
cat > "$T/consts.py" <<'EOF'
MODES = ["fast", "slow", "auto"]


def apply_all(rows):
    for r in rows:
        for m in MODES:
            emit(r, m)
EOF
hasnt "JS: loop over a literal array is O(1)" consts.ts bigo high 'applyAll'
hasnt "PY: loop over a literal list is O(1)"  consts.py bigo high 'apply_all'

echo
echo "── braceless bodies do not swallow their siblings ──"
cat > "$T/braceless.ts" <<'EOF'
export function three(a, b, c) {
  for (const x of a) use(x)
  for (const y of b) use(y)
  for (const z of c) use(z)
}
EOF
out="$(python3 "$CHK" bigo "$T/braceless.ts" --min-sev high 2>&1)"
if printf '%s' "$out" | grep -q "clean"; then ok "sibling braceless loops are not nested"
else bad "braceless bodies ran together: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
out="$(python3 "$CHK" bigo "$T/braceless.ts" --min-sev low 2>&1)"
printf '%s' "$out" | grep -qE 'n\^[0-9]{2}|n⁵ or worse' \
  && bad "absurd exponent from runaway nesting" || ok "no absurd exponent"

echo
echo "── masking + robustness ──"
cat > "$T/mask.ts" <<'EOF'
// a comment mentioning for (let i = 0; i <= xs.length; i++) must not be parsed
const url = "https://example.com//path";
const re = /\/\/[a-z]+/g;
const tpl = `value: ${items.length} // not a comment`;
export function real(xs) {
  return xs.length;
}
EOF
hasnt "code inside a comment ignored" mask.ts all low 'i <= xs.length'
hasnt "// inside a string ignored"    mask.ts fluff low 'restates'
out="$(python3 "$CHK" all "$T/mask.ts" --min-sev low 2>&1)"
if [ $? -le 2 ]; then ok "masker survives regex/template/url"; else bad "masker crashed: $out"; fi

printf 'def broken(:\n  pass\n' > "$T/syntax.py"
out="$(python3 "$CHK" all "$T/syntax.py" --min-sev low 2>&1)"; rc=$?
if [ "$rc" = "0" ] && ! printf '%s' "$out" | grep -qi traceback; then
  ok "unparsable file → silent, never a guess"
else bad "unparsable file: rc=$rc out=${out:0:80}"; fi

printf 'hello\n' > "$T/notcode.md"
out="$(python3 "$CHK" all "$T/notcode.md" --min-sev low 2>&1)"
if printf '%s' "$out" | grep -q "clean"; then ok "non-source file skipped"; else bad "non-source: $out"; fi

echo
echo "── --lines scoping (what the edit gate relies on) ──"
out="$(python3 "$CHK" bigo "$T/cost.ts" --lines 1-8 --min-sev high 2>&1)"
if printf '%s' "$out" | grep -q "enrich — est" && ! printf '%s' "$out" | grep -q "accumulate"; then
  ok "--lines reports only the given range"
else bad "--lines leaked outside its range: $(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
out="$(python3 "$CHK" bigo "$T/cost.ts" --lines 500-600 --min-sev high 2>&1)"; rc=$?
if [ "$rc" = "0" ]; then ok "--lines outside the file → clean, exit 0"; else bad "empty range rc=$rc"; fi

echo
echo "── exit codes ──"
python3 "$CHK" bigo "$T/cost.py" --min-sev high --quiet >/dev/null 2>&1
[ $? -eq 2 ] && ok "findings → exit 2" || bad "findings should exit 2"
python3 "$CHK" bigo "$T/cost.py" --min-sev certain --quiet >/dev/null 2>&1
[ $? -eq 0 ] && ok "clean at threshold → exit 0" || bad "clean should exit 0"
python3 "$CHK" nonsense "$T/cost.py" >/dev/null 2>&1
[ $? -eq 1 ] && ok "bad usage → exit 1" || bad "bad usage should exit 1"
# Capture first: under `pipefail` the checker's exit 2 (findings) would become the
# pipeline's status and fail this check even with perfectly valid JSON.
jout="$(python3 "$CHK" bigo "$T/cost.py" --json 2>/dev/null || true)"
if printf '%s' "$jout" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "findings" in d and "summary" in d' 2>/dev/null; then
  ok "--json is valid and has a summary"
else bad "--json malformed"; fi

echo
echo "════ $pass passed, $fail failed ════"
[ "$fail" -eq 0 ]
