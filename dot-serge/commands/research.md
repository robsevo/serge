---
name: research
description: Deep-research mode for one question — parallel multi-angle researcher passes plus an interpreting synthesis, all $0
---

# Research — multi-angle deep research on a question

Research the question in $ARGUMENTS with a parallel panel on the free lanes. If $ARGUMENTS is empty, ask what to research. If on reflection the question is genuinely a single lookup, answer it with one search and say the panel wasn't warranted — do not convene machinery for show.

1. **FRAME** — restate what decision or understanding the research must serve, what a complete answer has to cover, and what evidence would change the verdict. From that, name the 2-4 angles that together cover the question (typical cuts: official docs/specs; community experience and known failure modes; alternatives and comparisons; costs, limits, and licensing). This framing becomes the shared brief.

2. **FAN OUT** — spawn one `researcher` agent PER ANGLE, IN PARALLEL (2-4 of them), each given the shared brief plus its single assigned angle and told to stay in its lane. They're free — don't ration them; a partitioned panel beats one sequential sweep. If the question also turns on reasoning rather than facts (a tradeoff, a design implication, a "should I"), add one `think` agent deriving what the answer *ought* to be from first principles, blind to the search results — its job is to disagree if the found consensus doesn't hold up.

3. **RECONCILE** — read the briefs side by side. Where sources conflict, name the conflict and either resolve it (which source is stronger and why) or carry it forward as an open question — never average it away. Where the think pass disagrees with the found consensus, treat that as a signal to run one targeted follow-up search on the crux, not as noise to smooth over.

4. **SYNTHESIZE** — written by you, not stitched from the briefs: the answer first in two or three sentences; then the detailed findings organized around what the user actually needs to decide, each load-bearing claim carrying its source and an explicit confidence label ("confirmed by N sources" / "reported by X, not independently confirmed"); then what remains uncertain and what would settle it. Interpret throughout — say what the findings mean for the user's situation, never just what the sources said. Numbers carry units, dates are absolute, and detail earns its place: depth through evidence, not padding.

$ARGUMENTS
