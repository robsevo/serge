---
name: logic
description: Deterministic propositional-logic toolkit (logic_check.py — truth tables, equivalence proofs with counterexamples, tautology/dead-branch detection) plus the nested-conditional refactor workflow and the debugging-fallacy checklist. Evidence-grounded — models must not hand-evaluate boolean logic; they translate, the tool decides.
whenToUse: Use whenever refactoring or reviewing a nontrivial boolean condition (De Morgan flips, guard merges/splits, negation pushes), flattening nested if/else, hunting a dead or always-taken branch, or diagnosing "this condition looks right but behaves wrong". Also load during root-cause debugging to run the fallacy checklist before committing to a diagnosis.
---

# Logic — translate, then let the tool decide

## The rule (evidence, not vibes)

Measured result (2026): prompting a model with logic rules/truth tables has mixed-to-
NEGATIVE effect on its accuracy, while translating conditions into formal expressions
and letting a **deterministic solver** evaluate them wins consistently (the Logic-LM /
LINC neurosymbolic split). So in serge:

**Never claim two boolean conditions are equivalent from inspection. Translate both
into `logic_check.py` syntax and run `equiv`. The tool's verdict — with its
counterexample — is the answer.**

Tool: `~/.serge/skills/logic/logic_check.py` (stdlib-only, AST-whitelisted, ≤16 vars
exhaustive, fails loudly on anything that isn't pure boolean logic):

```
logic_check.py equiv "not (a and b)" "not a or not b"     # refactor-safety proof
logic_check.py sat   "logged_in and not logged_in"        # can this branch EVER fire?
logic_check.py taut  "x or not x"                         # always-true guard = dead else
logic_check.py implies "is_admin and active" "is_admin"   # premise ⇒ conclusion?
logic_check.py table "a and (b or not c)"                 # small truth table to reason over
```

Exit codes: 0 = holds, 2 = fails (counterexample printed), 1 = rejected input.
Translate code predicates to bare names first (`user.age >= 18` → `adult`) — keep a
legend in your working notes so the counterexample maps back to real code.

## Nested-conditional refactor workflow

1. **Extract** the condition tree verbatim; name each atomic predicate.
2. **Prove the current shape**: `table` the original if it's ≤4 vars; note which rows
   reach which branch.
3. **Refactor** toward guard clauses / early returns (depth ≤2 is the target).
4. **Prove equivalence**: `equiv` original vs refactored for every branch condition.
   NOT-EQUIVALENT with a counterexample = you changed behavior; either that's the bug
   you meant to fix (say so) or your refactor is wrong.
5. **Check reachability**: `sat` each branch guard; UNSAT = dead code — delete it or
   fix the guard, never ship it silently.

## Debugging-fallacy checklist (root-cause lanes)

Run through these BEFORE committing to a diagnosis; each is a named failure that has
burned real debugging sessions:

- **Affirming the consequent** — "the fix made the symptom vanish once, so that was
  the cause." Re-run; demand the mechanism. A vanished symptom under retry-prone
  infra proves little.
- **Post hoc** — "X changed, then Y broke, so X broke Y." Correlated timing in logs
  is a lead, not a verdict; find the causal path or say you haven't.
- **Denying the antecedent** — "the code path requires the flag; the flag is off, so
  the path can't run." Only if the flag is the ONLY way in — `implies` check it.
- **False dichotomy** — "it's either the client or the server." Enumerate the
  surfaces first (feature-flow A–Z); the bug often lives in the third place.
- **Survivorship** — "works on my machine / the passing runs look fine." The failing
  population is the evidence; go read a failing run.

## Anti-patterns
- Eyeballing a De Morgan flip in review and calling it equivalent.
- "Simplifying" a guard without an `equiv` proof, then shipping the behavior change.
- Leaving a branch you suspect is dead ("probably unreachable") without a `sat` verdict.
- Asking a model to fill in a truth table by hand — that's the measured failure mode
  this skill exists to prevent.
