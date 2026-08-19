---
name: deepthink
description: Deep-reasoning mode for one hard question — parallel Magistral self-consistency passes plus an adversarial reconcile, all $0
---

# Deepthink — parallel self-consistency on a hard question

Answer the question in $ARGUMENTS with a self-consistency panel on the free deep-reasoning lane. If $ARGUMENTS is empty, ask what the question is. If on reflection the question is actually easy, just answer it and say the panel wasn't warranted — do not convene machinery for show.

1. **FRAME** — restate the question in your own words: the exact decision or claim at stake, the constraints treated as fixed, and what a complete answer must cover. This framing becomes the shared brief.

2. **FAN OUT** — spawn 3 `think` agents IN PARALLEL, each given the same brief plus a distinct assigned angle: (a) a first-principles derivation toward the answer; (b) an empirical/counterexample hunt — try to construct the case that breaks the natural answer; (c) an adversarial pass — argue the strongest case that the obvious answer is wrong. Distinct angles are the point: diversity catches what redundancy cannot.

3. **RECONCILE** — read the three verdicts side by side. If they agree, spawn ONE more `think` agent as a dedicated refuter: hand it the consensus answer plus the strongest objection raised, with the sole job of breaking it. If they disagree, name the crux — the single proposition on which they split — and spawn one `think` agent on that crux alone.

4. **SYNTHESIZE** — yourself, not by vote-counting: the final answer, the reasoning that earns it, which objections survived and why they don't (or do) change the verdict, and an honest confidence. Never average away a genuine conflict — if the panel truly splits, present both positions and decide on the merits, saying so.

Escalate to the `reasoning` or `architect` seat (scarce shared brain quota, ~20 requests/day) ONLY if the panel deadlocks on a crux a stronger model would settle — and say that's why you're spending it.

$ARGUMENTS
