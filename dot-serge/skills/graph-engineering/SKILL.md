---
name: graph-engineering
description: How to structure multi-agent work as an explicit graph — draw the work graph (jobs + dependency edges) before spawning, carry context across node boundaries on purpose via the handoff ledger, declare a failure rule per node, and decide parallel-vs-sequential from the DAG instead of by feel. Includes the gate for when NOT to graph (open-ended discovery), and the return-shape contract that makes fan-in synthesis honest.
whenToUse: Use before spawning more than one subagent, when a task needs several specialists in some order, when deciding what can run in parallel, when a multi-specialist task is losing information between seats ("the reviewer didn't know about X"), or when planning any workflow with stages/handoffs. Also load when a council/Tier-2 deliberation is about to be convened, or when a subagent returns something that doesn't compose with the others.
---

# Graph engineering — program the organization, not just the agent

Loops make one agent's *behavior* programmable. Graphs make an *organization of
agents* programmable. Serge already runs loops well (council.md's ladder, the
escalation rule, the stop gates); what follows is the layer above that — and the
single failure mode it exists to prevent.

## The one rule (this is the whole failure mode)

**Context does not cross a node boundary unless an edge carries it.**

A subagent is memory-blind and CLAUDE.md-blind by design — the brief is its entire
world. So every fact a downstream seat needs is either written onto the edge that
reaches it, or it does not exist for that seat. The failure is *silent*: the
downstream agent doesn't error, it confidently produces work built on information it
never had. Missing edge → confidently wrong output, no exception raised.

The corollary, from three years of production graph work (LangGraph) and the
practitioner consensus around it: *"Loops are forgiving. Graphs force you to admit
how much of the workflow you haven't actually modeled yet."* If drawing the graph
feels like busywork, that is usually the moment it's about to catch something.

## GATE — when NOT to draw a graph

Run this gate first; it is the most expensive mistake in this layer, and the
evidence is unusually clean. LangChain built deep research on LangGraph and then
**migrated off it**, concluding that for open-ended work "planning and delegation
shouldn't be hardcoded in the graph."

**Do NOT pre-draw a graph when the path is not knowable up front:**
- open-ended research and discovery ("find out why X", "what's out there for Y")
- debugging where the next step depends entirely on what the last step found
- anything where a wrong early node sends every downstream node the wrong way

For those: run **one agentic loop** with a real stop condition (a test, a schema, a
checker), let it discover the path, and structure only afterward. Forcing discovery
into a fixed DAG buys false confidence — you get a tidy diagram over an unmodeled
problem.

**DO draw the graph when the shape is knowable:** a known set of jobs, a known
order, several independent areas to cover, or a task where specific specialists
must see specific prior results. Most build/review/migrate/audit work is this.

Loops and graphs are one spectrum, not rivals — a loop is a small cyclic graph.
Pick by whether the path is *discoverable in advance*, not by task size.

## Serge's two graphs

Production systems run two graphs at once. Serge already has both; naming them is
what makes them checkable.

**Org graph — stable, changes on redeploy.** This is `~/.serge/agents/*.md`: named
seats that own a zone and accumulate domain framing — `scout`, `reviewer`,
`architect`, `debugger`, `frontend`/`frontend-pro`, `backend`, `security`, `test`,
`devops`, `reasoning`, `researcher`, `data`, `gamedev`, `think`. The seat ladder and
quota tiers in `council.md` are its routing rules (scarce brain seats vs plentiful
free seats). **You do not redraw the org graph per task.** Answers *who owns what*.

**Work graph — ephemeral, drawn per task, discarded after.** Nodes are *jobs*, edges
are *execution dependencies*. It adapts as evidence arrives: nodes can spawn, merge,
reorder, or vanish mid-task. Answers *what needs doing now, in what order*.

The recurring mistake is skipping the work graph because the org graph exists —
having named seats is not the same as having decided who runs when, on what input.

## Drawing the work graph (four steps, before any spawn)

1. **Jobs.** List the actual units of work, as jobs not seats ("map every call site
   of `resolveStream`", not "a scout"). If two jobs would return the same finding,
   they're one job.
2. **Dependency edges.** For each job, name what must finish first *and why*. No
   stated reason → not a real dependency → it's parallel. This is where invented
   sequencing dies.
3. **Context edges.** For each job, list what it must be *told* — which prior
   findings, file:line refs, constraints, and failed attempts ride its brief. This is
   the step that prevents the silent failure above. Write it down before spawning.

   **If you haven't looked yet, look before you brief.** The constraint that makes a
   brief wrong usually lives in the environment, not in the conversation: deploy/ops
   notes, resource ceilings (RAM, connections, rate limits), ports already taken, the
   test runner and conventions actually in use, the config the code really reads.
   Measured on serge's own behavioral eval (`evals/graph-behavior/`): asked to split
   a feature across three subagents, the driver produced three well-scoped, genuinely
   competent briefs — correct objectives, clear outputs — and carried **none** of the
   deploy constraints, briefing an agent to add a Redis process to a box with 128 MB
   of headroom without mentioning the ceiling, and specifying Jest in a Vitest repo.
   Decomposing the work is the easy half. It is not the half that fails.
4. **Failure rule per node.** Decide in advance, per node: retry / route to a
   fallback seat / escalate to a stronger lane / abort this branch. Undeclared →
   a mid-task failure gets improvised, and improvised recovery is where the graph
   quietly turns into one confused agent.

Then assign seats to jobs using the council ladder — jobs first, seats second.
Assigning seats first is how a task ends up shaped like the roster instead of the
problem.

## Parallel vs sequential comes from the DAG

Two jobs run in **parallel** iff neither is on the other's dependency path *and*
their scopes don't overlap. Overlapping scopes aren't a correctness bug, they're
paid-twice tokens re-finding the same thing.

They run in **sequence** only when the later one genuinely needs the earlier one's
output — a reviewer must see the architect's actual plan to critique it, not just
the problem.

Fan-out where independent (several scouts, non-overlapping areas; parallel reviewers
with *distinct lenses* — correctness, security, simplicity). Fan-in at one synthesis
node. The default failure here is a serial chain that was never actually serial.

## Cycles are normal — bound them

Production graphs are **not** acyclic. Retry, RETHINK, and escalation are cycles and
they're load-bearing. What makes a cycle safe is a bound and an exit:
- 2 failed attempts by one seat on the same job = the approach or the seat is wrong;
  the third attempt goes to a **different, stronger lane**, and its brief opens with
  the post-mortem of both failures. Re-running the same path with more horsepower is
  the classic waste.
- Every cycle needs a mechanical exit test. A cycle that cannot distinguish *done*
  from *stuck* does not fail loudly — it just keeps spending.

## The edge ledger — how context actually crosses

`handoff.md` (beside `plan.md`, reset when a new plan starts) is the physical carrier
for context edges. After each node returns, append its load-bearing decisions,
interfaces, and gotchas as 2–4 attributed lines.

**Pre-spawn check — do this every time, it takes one line of thought:**
> "Which ledger lines does this node need, and which does it not?"

Carry the relevant lines plus relevant memory lines into the brief. Not the whole
ledger — a dumped ledger is as bad as an empty one, because the signal the node
needed is buried in the noise it didn't. Distilling once per edge is the work.

## Return shape — declare it, or fan-in is guesswork

Every node's brief states the **exact output expected**: the fields, the format, and
whether file:line evidence is required. Nodes that return prose in whatever shape
they like cannot be composed — synthesis degrades into re-reading raw dumps, which is
exactly the context bloat delegation was supposed to prevent.

At fan-in: weigh results on merit, surface genuine disagreement rather than averaging
it away, and treat any node's confident claim as a hypothesis to verify. Consensus
between two nodes that both received the same incomplete brief is not corroboration —
it's one error, twice.

## What to trace (observability)

When a multi-node task goes wrong, the diagnosis is almost always one of four things
— check them in this order:
1. **A missing context edge** — which node acted without a fact it needed? (start here; it's the usual answer)
2. **A wrong return shape** — did fan-in silently drop something?
3. **A dependency that wasn't real** — did the chain serialize work that could have run wide?
4. **An unbounded cycle** — did a seat retry the same failed approach?

Worth noting per node when the task is large: order, wall-clock, token cost, and
which evidence caused the work graph to be rewritten mid-task.

## Anti-patterns

- Spawning subagents before drawing the work graph — "I'll send a scout and see."
- Assigning seats before defining jobs, so the task takes the roster's shape.
- A brief that omits the failed attempts — the new seat repeats them.
- Dumping the whole ledger (or the raw repo) onto an edge instead of distilling it.
- Serializing independent jobs because the roster is listed in an order.
- Parallel reviewers with the *same* lens — three passes, one blind spot.
- Pre-drawing a rigid graph for open-ended research, then following it past the
  point the evidence contradicted it.
- Calling a fixed pipeline "the graph" and never redrawing it when the evidence moves.
