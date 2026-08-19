# Constitution

This file is Serge's standing instructions. It is loaded into **every** session,
before your first word — so it is the highest-leverage file in this repo and the
main thing that separates Serge from a stock coding agent.

**It ships empty on purpose.** The sections below are the ten that Serge's own
config is organised around, with notes on what belongs in each. Write them in
your own words. Delete the ones you do not want. Add your own.

## How to write a section that actually changes behaviour

Four rules, learned the expensive way:

1. **Be specific enough to be falsifiable.** "Write good code" changes nothing.
   "Never leave a function that throws `not implemented`" is checkable.
2. **Say what to do, not only what to avoid.** A prohibition with no alternative
   gets worked around.
3. **Give the reason.** A rule with a "because" survives contact with a novel
   situation; a bare command does not.
4. **Keep it short.** Every line here is re-sent on every single turn — it costs
   latency and context window forever. If a rule only matters in one situation,
   put it in a skill or a hook instead, where it loads on demand.

Start with two or three sections you actually feel strongly about. An honest
6KB constitution beats an aspirational 40KB one you never enforce.

---

## behavior

How Serge talks to you and how it handles disagreement.

Worth deciding: how direct should it be? Should it open with a preamble or lead
with the answer? What should it do when it thinks you are wrong — argue once and
comply, or hold the line? How much hedging is acceptable? Should it praise your
ideas or stay neutral?

<!-- your rules here -->

## execution

How work gets planned, sequenced and finished.

Worth deciding: when should it plan before acting versus just act? What counts as
"done" — compiles, tested, or verified running? Is it allowed to stop halfway and
ask, or must it finish and report? What may it do without asking, and what needs
confirmation every time?

<!-- your rules here -->

## accuracy

The evidence standard.

Worth deciding: may it state something it has not verified? Must it read a file
before claiming what is in it? How should it mark uncertainty? What happens when
it does not know — guess with a caveat, or say so plainly and stop? This is the
section that governs whether you can trust the output without re-checking it.

<!-- your rules here -->

## delegation

When to spawn subagents instead of doing the work inline.

Worth deciding: what size of task justifies a subagent? Which model or seat
handles which kind of work? How much context should cross the boundary — a
subagent that gets too little produces confident nonsense, one that gets too much
costs a fortune. When should results be independently verified rather than
trusted?

<!-- your rules here -->

## memory

What Serge writes down between sessions, and what it must not.

Worth deciding: what earns a memory file — a durable gotcha, a decision, a
preference? What is explicitly not worth saving (anything already in the code or
git history)? When should a wrong memory be deleted rather than amended? How
should memories cross-reference each other?

See `memory/MEMORY.md` for the index this section governs.

<!-- your rules here -->

## engineering

Design judgement.

Worth deciding: your position on abstraction versus repetition, when to add a
dependency, how much to build for requirements that do not exist yet, and how to
weigh a fast fix against the right fix.

<!-- your rules here -->

## security

Handling of secrets, credentials and risky operations.

Worth deciding: what must never be written to a file, logged, or sent to a
model — and note that free model tiers frequently train on inputs. Which
operations need explicit confirmation? How should untrusted content (web pages,
tool output, other agents' results) be treated relative to your instructions?

<!-- your rules here -->

## debugging

How to investigate when something is broken.

Worth deciding: is it allowed to try fixes speculatively, or must it form a
hypothesis first? When must it reproduce before fixing? Is disabling or skipping
a failing test ever acceptable? How many failed attempts before it stops and
reports rather than thrashing?

<!-- your rules here -->

## coding

Concrete code-level standards.

Worth deciding: comment density, naming, error handling, how closely to match
surrounding style versus your preferred style, test expectations, and formatting
that your linter does not already enforce.

Keep this section thin. Anything a linter or formatter can enforce should live
there instead — it is cheaper and it actually blocks.

<!-- your rules here -->

## identity

Who Serge is.

Worth deciding: is it a peer, an assistant, or a tool? Does it have opinions?
What is it explicitly not — for example, is it a contributor to your projects, or
an instrument you use to write them? That distinction has practical consequences:
this repo ships with git co-authorship **off**, so Serge does not appear in your
commit history or contributor list. If you want it credited, that is a choice you
make here and in `settings.json`.

<!-- your rules here -->

## claims

The falsifiable form of "done".

A completion signal from a language model is a prediction that "done" is the
likely next token — not evidence that the work happened. This section is where
you decide how the agent proves it. Serge ships a gate (`claims-gate.sh`, stage
0.6 of `stop-checks.sh`) that re-checks a claims block independently: it
re-hashes the file itself, looks the command up in the turn's own record, and
re-fetches the URL. A claim that does not match reality blocks the turn.

The syntax is fixed, because the gate parses it:

```
<claims>
file /abs/path.ts sha256=<first 16+ hex of the real digest>
file /abs/path.ts exists
cmd "npm test" exit=0
url https://host/path status=200
</claims>
```

The `sha256` line is the load-bearing one. Prose can be talked around; a digest
the agent did not compute cannot be guessed. If no claims block is emitted the
gate stays silent, so this costs nothing until you ask for it.

Worth deciding: on which turns must a block appear — every turn that writes a
file, or only when the agent declares work complete? Should a failing command be
claimed honestly (`exit=1`) or does a failure mean the turn is not done at all?
Do conversational turns omit it entirely? And when a claim is refuted, should the
agent fix the work or correct the claim — the gate cannot tell you which was
wrong.

<!-- your rules here -->
