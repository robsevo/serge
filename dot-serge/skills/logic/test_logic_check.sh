#!/usr/bin/env bash
# Known-answer + validation + edge tests for logic_check.py. No network, no LLM.
set -uo pipefail
LC="$(dirname "$0")/logic_check.py"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

# 1. known-answer: De Morgan equivalence holds (exit 0)
out=$(python3 "$LC" equiv "not (a and b)" "not a or not b"); rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q EQUIVALENT; then ok "De Morgan equiv proven"
else bad "De Morgan equiv failed (rc=$rc out=$out)"; fi

# 2. inequivalence caught WITH counterexample (exit 2)
out=$(python3 "$LC" equiv "a or b" "a and b"); rc=$?
if [ "$rc" = "2" ] && printf '%s' "$out" | grep -q "counterexample"; then ok "inequivalence → counterexample"
else bad "inequivalence not caught (rc=$rc out=$out)"; fi

# 3. tautology detected
out=$(python3 "$LC" taut "x or not x"); rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q TAUTOLOGY; then ok "tautology detected"
else bad "tautology missed (rc=$rc)"; fi

# 4. dead branch: unsatisfiable condition (exit 2)
out=$(python3 "$LC" sat "flag and not flag"); rc=$?
if [ "$rc" = "2" ] && printf '%s' "$out" | grep -q UNSAT; then ok "dead branch (unsat) detected"
else bad "unsat missed (rc=$rc out=$out)"; fi

# 5. implication: holds and fails correctly
r1=$(python3 "$LC" implies "a and b" "a" >/dev/null; echo $?)
r2=$(python3 "$LC" implies "a" "a and b" >/dev/null; echo $?)
if [ "$r1" = "0" ] && [ "$r2" = "2" ]; then ok "implies: a∧b⇒a holds, a⇒a∧b fails"
else bad "implies wrong (r1=$r1 r2=$r2)"; fi

# 6. injection/arbitrary code REJECTED loudly (exit 1), incl. dunder + call forms
r1=$(python3 "$LC" sat "__import__('os').system('id')" >/dev/null 2>&1; echo $?)
r2=$(python3 "$LC" table "(lambda: True)()" >/dev/null 2>&1; echo $?)
r3=$(python3 "$LC" sat "a + b" >/dev/null 2>&1; echo $?)
if [ "$r1" = "1" ] && [ "$r2" = "1" ] && [ "$r3" = "1" ]; then ok "non-boolean/injection input rejected loudly"
else bad "unsafe input not rejected (r1=$r1 r2=$r2 r3=$r3)"; fi

# 7. var cap enforced (17 vars > 16 cap → exit 1)
expr=$(python3 -c "print(' or '.join(f'v{i}' for i in range(17)))")
r=$(python3 "$LC" sat "$expr" >/dev/null 2>&1; echo $?)
if [ "$r" = "1" ]; then ok "17-variable expression rejected (exhaustive cap)"
else bad "var cap not enforced (rc=$r)"; fi

# 8. truth table shape: 2 vars → header + 4 rows
n=$(python3 "$LC" table "a and b" | wc -l)
if [ "$n" = "5" ]; then ok "truth table has header + 4 rows for 2 vars"
else bad "table row count wrong ($n)"; fi

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — logic_check trustworthy"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
