---
name: consensus
description: High-stakes answer via parallel independent attempts on diverse model seats, anonymous cross-review, and a reasoned vote — MassGen-style redundancy, all $0
---

# Consensus — parallel attempts, cross-review, vote

Run the task in $ARGUMENTS through independent parallel attempts and collective validation. If $ARGUMENTS is empty, ask what to decide. If on reflection the task is routine — one obvious right answer, cheap to verify directly — just do it and say the panel wasn't warranted; never convene machinery for show.

Use this for wide-solution-space or high-stakes work: a design or architecture call, a tricky diagnosis, an answer that would be expensive to get wrong, "are we sure?" moments. Diversity is the engine — attempts must come from DIFFERENT model seats (workhorse `local-coder`, `think`, `reviewer`'s independent non-Claude voice), never N copies of one model, because shared blind spots defeat the vote.

1. **FRAME** — restate the task, the constraints that bind every attempt, and the criteria a winning answer must meet (correctness, fit to the codebase/situation, simplicity, risk). This brief goes verbatim to every attempt.

2. **ATTEMPT** — spawn 2-4 agents on distinct seats, IN PARALLEL, each solving the FULL problem independently from the shared brief. No coordination, no peeking: independence now is what makes agreement later mean something. Each returns its complete answer plus the reasoning and evidence behind it.

3. **CROSS-REVIEW** — show each attempt the others' answers, anonymized and order-shuffled (label them A/B/C; never name the model — models favor their own style and defer to reputations). Each may critique the rivals and revise its own answer if genuinely persuaded; a revision must say what changed and why. One round is usually enough; run a second only if a critique surfaced a NEW load-bearing fact.

4. **VOTE** — each participant votes for the strongest answer INCLUDING rivals', judged against the FRAME criteria, one-sentence rationale each. Voting for your own is allowed but must survive the rationale. Clear winner → it stands. Split or all-self-votes → don't average: either run one targeted follow-up on the crux that divides them, or escalate the adjudication to the brain seat with all attempts, critiques, and rationales attached.

5. **PRESENT** — deliver the winning answer written by you, not pasted: the answer first, then why it won on the criteria, then any dissent worth keeping — a minority attempt that survives on a different assumption is a named risk with its trigger condition, not noise to discard. Close with one audit line so the machinery is verifiable from the answer alone: which seats participated, the explicit tally (e.g. 3-0, 2-1), and whether any attempt revised after cross-review — or that review was skipped because the attempts converged immediately. Never claim a panel that didn't run.

*(Pattern distilled from [MassGen](https://github.com/massgen/massgen), Apache-2.0 — parallel full-problem agents, intelligence sharing, consensus vote. No code vendored.)*

$ARGUMENTS
