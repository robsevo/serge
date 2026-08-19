---
name: logic
description: Prove or refute a boolean-logic claim deterministically with logic_check.py (truth tables, equivalence with counterexamples, dead-branch detection) instead of eyeballing it
---

# /logic — translate, then let the tool decide

Resolve the claim in $ARGUMENTS with `~/.serge/skills/logic/logic_check.py`, never by
inspection. If $ARGUMENTS is empty, ask for the condition(s) to check.

1. **TRANSLATE** — name each atomic predicate from the code (`user.age >= 18` → `adult`),
   keep a one-line legend, and rewrite the condition(s) in tool syntax (and/or/not, ==/!=).
2. **PICK the question**:
   - "are these two conditions the same?" → `equiv "e1" "e2"`
   - "can this branch ever run?" → `sat "guard"`
   - "is this guard always true (dead else)?" → `taut "guard"`
   - "does this guarantee that?" → `implies "premise" "conclusion"`
   - "show me the cases" → `table "expr"` (≤4 vars stays readable)
3. **RUN it** and report the tool's verdict verbatim — a counterexample is the answer,
   mapped back through your legend to real code values.
4. If the expression won't translate (arithmetic, quantifiers, state over time), say so
   plainly and reason it out loud instead — don't force a false translation.

Read `~/.serge/skills/logic/SKILL.md` for the refactor workflow and the debugging-fallacy
checklist.
