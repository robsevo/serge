#!/usr/bin/env python3
"""logic_check — deterministic propositional-logic toolkit for code work.

Why this exists (evidence, 2026-07-21): LLMs evaluating boolean logic "in
their head" are unreliable, and prompting them with logic rules/truth tables
has MIXED-to-negative measured effect (rule-elicitation prompting lowered
accuracy in controlled studies; arxiv 2507.03876). What consistently works is
the neurosymbolic split (Logic-LM, LINC): the model TRANSLATES the condition,
a deterministic solver EVALUATES it. This is that solver, sized for the logic
that appears in real code: guards, nested conditionals, De Morgan refactors.

Usage:
  logic_check.py table  "a and (b or not c)"      # full truth table
  logic_check.py taut   "a or not a"              # tautology? (always-true guard = dead else)
  logic_check.py sat    "a and not a"             # satisfiable? (can this branch EVER fire?)
  logic_check.py equiv  "not (a and b)" "not a or not b"   # refactor-safety proof
  logic_check.py implies "a and b" "a"            # does e1 guarantee e2?

Expression syntax = Python booleans: and, or, not, ==, !=, parentheses,
bare variable names, True/False. Anything else is REJECTED loudly (no eval of
arbitrary code — AST-whitelisted). Exhaustive over up to 16 variables.

Verdicts go to stdout; counterexamples/witnesses are printed as assignments.
Exit codes: 0 = property holds (taut/equiv/implies) or table/sat printed;
2 = property FAILS (counterexample shown); 1 = input rejected.
"""
import ast
import itertools
import sys

MAX_VARS = 16

ALLOWED = (
    ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not,
    ast.Name, ast.Load, ast.Constant, ast.Compare, ast.Eq, ast.NotEq,
)


def parse(expr: str):
    try:
        tree = ast.parse(expr, mode="eval")
    except SyntaxError as e:
        print(f"PARSE ERROR in {expr!r}: {e}")
        sys.exit(1)
    for node in ast.walk(tree):
        if not isinstance(node, ALLOWED):
            print(
                f"REJECTED {expr!r}: '{type(node).__name__}' is not allowed — "
                "pure boolean expressions only (and/or/not, ==/!=, names, True/False)"
            )
            sys.exit(1)
        if isinstance(node, ast.Constant) and not isinstance(node.value, bool):
            print(f"REJECTED {expr!r}: only True/False constants are allowed")
            sys.exit(1)
    names = sorted({n.id for n in ast.walk(tree) if isinstance(n, ast.Name)})
    if len(names) > MAX_VARS:
        print(f"REJECTED: {len(names)} variables exceeds the {MAX_VARS}-var exhaustive cap")
        sys.exit(1)
    return compile(tree, "<expr>", "eval"), names


def assignments(names):
    for vals in itertools.product([False, True], repeat=len(names)):
        yield dict(zip(names, vals))


def fmt(env):
    return ", ".join(f"{k}={'T' if v else 'F'}" for k, v in env.items())


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd, e1 = argv[1], argv[2]

    if cmd == "table":
        code, names = parse(e1)
        print("  ".join(names + ["=>", e1]))
        for env in assignments(names):
            v = eval(code, {"__builtins__": {}}, env)
            print("  ".join(["T" if env[n] else "F" for n in names] + ["=>", "T" if v else "F"]))
        return 0

    if cmd in ("taut", "sat"):
        code, names = parse(e1)
        for env in assignments(names):
            v = eval(code, {"__builtins__": {}}, env)
            if cmd == "taut" and not v:
                print(f"NOT a tautology — counterexample: {fmt(env)}")
                return 2
            if cmd == "sat" and v:
                print(f"SATISFIABLE — witness: {fmt(env) if env else '(no variables)'}")
                return 0
        if cmd == "taut":
            print("TAUTOLOGY — true under every assignment (an else-branch guarded by its negation is DEAD)")
            return 0
        print("UNSATISFIABLE — this condition can NEVER be true (dead branch)")
        return 2

    if cmd in ("equiv", "implies"):
        if len(argv) < 4:
            print(f"{cmd} needs two expressions")
            return 1
        e2 = argv[3]
        c1, n1 = parse(e1)
        c2, n2 = parse(e2)
        names = sorted(set(n1) | set(n2))
        if len(names) > MAX_VARS:
            print(f"REJECTED: combined {len(names)} variables exceeds the {MAX_VARS}-var cap")
            return 1
        for env in assignments(names):
            v1 = eval(c1, {"__builtins__": {}}, env)
            v2 = eval(c2, {"__builtins__": {}}, env)
            if cmd == "equiv" and bool(v1) != bool(v2):
                print(f"NOT EQUIVALENT — counterexample: {fmt(env)}  ({e1!r}={'T' if v1 else 'F'}, {e2!r}={'T' if v2 else 'F'})")
                return 2
            if cmd == "implies" and v1 and not v2:
                print(f"DOES NOT IMPLY — counterexample: {fmt(env)}  (premise true, conclusion false)")
                return 2
        print("EQUIVALENT — identical on all assignments (refactor is behavior-preserving)"
              if cmd == "equiv" else "IMPLIES — whenever the premise holds, the conclusion holds")
        return 0

    print(f"unknown command {cmd!r} — one of: table, taut, sat, equiv, implies")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
