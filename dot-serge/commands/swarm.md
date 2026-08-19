---
name: swarm
description: Toggle swarm mode — parallel agents with their own doctrine, fan-out width and measures
argument-hint: "[agents N | only <types> | measure <name> | measures | doctrine | off]"
allowed-tools: Bash($SERGE_HOME/swarm.sh:*)
---

# Swarm mode

Bare `/swarm` **toggles it**. Everything else is a setting.

Run `$SERGE_HOME/swarm.sh $ARGUMENTS` — with no arguments that toggles;
with arguments it applies the setting. Then show the user what it printed,
trimmed to what changed. Don't narrate the config file.

## What it actually does

Two injections, both off unless swarm mode is on:

- **The lead** (each prompt) gets the fan-out width and the briefing rules — how
  many agents at once, split by area not by file, self-contained briefs.
- **Each subagent** (at spawn) gets the doctrine: stay in your slice, cite
  `file:line`, report what you couldn't determine, don't spawn further agents.

The doctrine lives in `~/.serge/swarm-doctrine.md` and is the user's to edit.
Optional **measures** — `persistence`, `no-speculation`, `frugal` — are separate
files in `~/.serge/swarm-measures/`, switched on individually. Any `.md` the
user drops in that directory becomes a measure; nothing needs to be registered.

## Not the same thing as /hive

Say so if the user seems to be reaching for one and means the other:

- **`/hive`** is an *effort* dial — when to escalate to the scarce architect
  seat on hard work.
- **`/swarm`** is a *fan-out* dial — how many agents run in parallel and what
  rules each one carries.

They compose. Neither implies the other.

## Settings

| | |
|---|---|
| `/swarm` | toggle on/off |
| `/swarm agents 5` | up to 5 parallel subagents |
| `/swarm only reviewer\|security` | doctrine for those agent types only (`*` for all) |
| `/swarm measures` | list measures and which are on |
| `/swarm measure persistence` | toggle one measure |
| `/swarm doctrine` | print the doctrine file |
| `/swarm lead off` | keep doctrine, stop briefing the lead |

## Cost, and when to say it

While off, both hooks exit before reading anything — it is free. While on, the
doctrine is injected **once per spawned agent**, so its cost is the doctrine
length multiplied by the fan-out width. `swarm.sh` reports this as
`~N words × M agents`.

Mention it only when it matters: if the user sets a wide fan-out and has several
measures on, tell them the multiplied cost once. Don't editorialise about it
every time they toggle.

## Editing the doctrine

If the user wants to change what the swarm believes, that is the doctrine file —
open it and edit it directly. Keep edits short and behavioural; a rule that
doesn't change what an agent *does* is paying tokens per agent to say nothing.
For a new named measure, write `~/.serge/swarm-measures/<name>.md` and it shows
up in `/swarm measures` immediately.

Never turn swarm mode on or off on your own initiative — it changes how every
subsequent turn fans out, and that is the user's call.
