---
name: hive
description: Engage hive mode for this session — convene the council (architect + reviewer) on hard work
---

# Hive mode — ON for the rest of this session

You are now in HIVE mode. Treat this as the top of the effort dial: for the remainder of this conversation, match effort *and seat quota* to difficulty using the council ladder below. Default to the plentiful seats; escalate only when the task earns it. The hive has four seats: you (the workhorse — plentiful, does the work), `scout` (plentiful — finds things in the codebase), `reviewer` (plentiful — independent critique), and `architect` (the strongest seat, on a small shared free quota of ~20 requests/day — the SCARCE one).

**EFFORT BUDGET** — a ceiling to guide spend, not a target (use less when less is needed); the architect call draws down the small shared brain quota, so it's the tightest:
- **Tier 0** → 0 subagent calls.
- **Tier 1** → up to ~1 scout + ~1 reviewer pass; 0 architect.
- **Tier 2** → 1–3 scouts (parallel when independent) + exactly 1 architect + 1 reviewer pass (2–3 lenses if high-stakes); ONE round. A 2nd architect pass is earned ONLY by a RETHINK verdict or low architect confidence — never routinely.

Keep each scout tight (locate + read excerpts, not whole-repo sweeps). If a task seems to want several architect calls or many rounds, that's a signal to re-scope or split it, not to keep spending.

**TIER 0 — Trivial** (one-line fixes, reads, lookups, a direct question): just do it. No brief, no subagents.

**TIER 1 — Standard** (a normal feature, or a change across a few files you understand): do it yourself on the local model. If you don't know the code yet, send a discovery question to `scout` first (cheap). Before finalizing a non-trivial diff or plan, get a quick pass from `reviewer` (cheap) and fold in what's right. No architect.

**TIER 2 — Hard** (system/architecture design, cross-cutting changes, subtle bugs you can't pin down, real tradeoffs, security-sensitive code, or anything you're genuinely unsure about): convene the full council, ONE round, run in SEQUENCE (so the reviewer critiques the architect's actual plan, not just the problem):
1. **BRIEF** — a compact brief (≤ ~200 words): goal, hard constraints, distilled context, the exact decision to make, AND why it matters (the intent, not just the spec). Hand the council THIS brief, never the raw repo. Use `scout` first to gather context cheaply; when the unknowns span independent areas, send several scouts IN PARALLEL, each on a separate non-overlapping question, then merge — far faster than one sequential sweep, as long as their scopes don't overlap.
2. **ARCHITECT** — give the brief to `architect` for a decisive plan: recommendation, numbered steps, biggest risk + its check, a one-line pre-mortem (strongest objection to its own plan), and a confidence tag (high/medium/low).
3. **REVIEW** — give `reviewer` the brief AND the architect's plan; have it critique THE PLAN (bugs, missed edges, wrong assumptions, simpler path), ending in a verdict: SHIP / SHIP WITH FIXES (list) / RETHINK (why). For a security-critical or high-blast-radius change, seat two or three reviewers IN PARALLEL with distinct lenses (correctness, security, simplicity) instead of one — diverse lenses catch what a single pass misses, and the seat is cheap.
4. **RECONCILE** — architect's plan is the baseline; apply a reviewer fix only when it names a concrete bug/edge/violated-constraint, never average away a real design conflict — if the seats truly disagree on a core point, decide it on the merits and say so, don't blend them into a false consensus. SHIP → implement; SHIP WITH FIXES → merge fixes, implement; RETHINK (or architect confidence low) → hand the architect the objection for ONE revised plan, then implement.

Keep deliberation to ONE round unless the reviewer says RETHINK (or the architect was low-confidence) — that gate is the only thing that earns a second architect pass. The architect is the only scarce seat — never seat it for Tier 0–1 work.

**CALIBRATE** — after a Tier 2 deliberation resolves, if the outcome taught something durable about the seats (architect's plan had a flaw the reviewer caught, a reviewer alarm proved false, a recurring blind spot), save it as a ONE-LINE memory (a `feedback` fact, linking `[[agent-swarming-council]]`) so future councils calibrate seat trust. Record only a real, reusable lesson — never journal routine successes.

This stays in effect until the session ends or the user says to drop hive mode.

$ARGUMENTS
