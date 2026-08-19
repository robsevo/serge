---
name: debugging
description: The phased debugging process — root cause before ANY fix, one hypothesis at a time, and a hard stop that questions the architecture after 3 failed fixes. Includes reference techniques for backward root-cause tracing, defense-in-depth validation, and replacing arbitrary timeouts with condition polling.
whenToUse: Use on ANY bug, test failure, crash, regression, or unexpected behavior BEFORE proposing a fix — especially under time pressure, when a "quick fix" seems obvious, or when previous fixes didn't stick. Also when a fix attempt just failed (that's the moment guessing starts). Pairs with the debugger agent: this is the process; the agent is the specialist lane that runs it.
---

# Systematic debugging — no fixes without root cause

Random fixes waste time and create new bugs; quick patches mask real issues.

**The iron law: NO FIXES WITHOUT ROOT-CAUSE INVESTIGATION FIRST.** If Phase 1
isn't done, you may not propose fixes. This holds *especially* when it's
tempting to skip: emergencies, "simple" bugs, an impatient user — systematic
is faster than thrashing (typical: 15-30 min vs 2-3 hours; first-fix rate
~95% vs ~40%).

## Phase 1 — Root cause investigation

1. **Read the actual error.** Full message, full stack trace, line numbers,
   codes. It often contains the answer.
2. **Reproduce reliably.** Exact steps; every time? If not reproducible,
   gather more data — don't guess.
3. **Check what changed.** Diff, recent commits, new deps, config, env.
4. **Instrument the boundaries.** In multi-component systems (CI → build →
   sign; API → service → DB), log what enters and exits each component and
   verify config propagation — run once, see WHERE it breaks, then dig there.
5. **Trace bad values backward** to their origin — fix at the source, not
   where the symptom surfaced. Full technique: `root-cause-tracing.md`.

For stalls, hangs, exit-137, and "[Request interrupted]": triage per the
`resilient-external-calls` skill before blaming the API or the model.

## Phase 2 — Pattern analysis

Find working examples of the same pattern in this codebase; read reference
implementations COMPLETELY (skimming guarantees partial understanding); list
every difference between working and broken, however small — "that can't
matter" is how the cause hides; understand the dependencies and assumptions.

## Phase 3 — Hypothesis, tested minimally

State one specific hypothesis: "X is the root cause because Y." Test it with
the SMALLEST possible change — one variable at a time, never a batch of
fixes. Didn't hold? Form a new hypothesis; do NOT stack another fix on top.
Don't know? Say "I don't understand X" and investigate — never pretend.

## Phase 4 — Implementation

1. **Failing test first** — simplest reproduction, automated if possible.
2. **One fix**, addressing the identified root cause. No "while I'm here."
3. **Verify**: test passes, no others broke, the original failure is gone
   (re-run the reproduction, not just the suite).
4. After the root cause is fixed, consider validation at the layers the bad
   value passed through: `defense-in-depth.md`.

**The 3-strikes rule:** if 3+ fixes have failed, STOP. Each fix revealing a
new problem elsewhere, or needing "massive refactoring", means the
architecture is wrong — question the pattern with the user instead of
attempting fix #4. That's not a failed hypothesis; it's the wrong design.

## Red flags — any of these means: stop, return to Phase 1

"Quick fix for now" · "just try changing X" · multiple changes then run
tests · "skip the test, I'll verify manually" · "it's probably X" · "I don't
fully understand but this might work" · proposing solutions before tracing
data flow · "one more fix attempt" after 2+ failures.

| Rationalization | Reality |
|---|---|
| "Simple issue, skip the process" | Simple bugs have root causes too; the process is fast on them |
| "Emergency — no time" | Systematic beats guess-and-check thrashing on the clock |
| "I'll write the test after the fix works" | Untested fixes don't stick |
| "Multiple fixes at once saves time" | Can't isolate what worked; breeds new bugs |
| "I see the problem, let me fix it" | Seeing a symptom ≠ understanding the cause |

If investigation truly ends at "environmental / timing / external": document
what was ruled out, handle it properly (retry, timeout, clear error), add
monitoring. But 95% of "no root cause" is incomplete investigation.

References in this directory: `root-cause-tracing.md` (backward tracing),
`defense-in-depth.md` (multi-layer validation), `condition-based-waiting.md`
(kill arbitrary sleeps in tests/scripts).

---
*Adapted from [obra/superpowers](https://github.com/obra/superpowers)
`systematic-debugging` (MIT, © 2025 Jesse Vincent — see LICENSE). Condensed
to house voice; wired to serge's debugger agent and resilient-external-calls.*
