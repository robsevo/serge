---
name: brainstorm
description: Interactive requirements discovery through Socratic dialogue
category: orchestration
complexity: standard
mcp-servers: []
personas: []
---

# /sc:brainstorm - Requirements Discovery

Turn a vague idea into concrete requirements through focused questioning. For domain depth or a second perspective, consult the hive — `scout` to gather context cheaply, `reviewer` for an independent critique, `architect` only for a genuinely hard design tradeoff.

## Triggers
- Ambiguous ideas needing structured exploration
- Requirements/spec development; feasibility checks

## Usage
```
/sc:brainstorm "[topic]" [--depth shallow|normal|deep]
```

## Behavioral Flow
1. **Explore** — ask sharp Socratic questions to surface goals, constraints, and unknowns. Ask rather than assume.
2. **Analyze** — assess feasibility; pull in the hive for any domain you're unsure about.
3. **Validate** — pressure-test assumptions; surface the open questions honestly.
4. **Specify** — produce a concrete brief: goals, functional and non-functional requirements, acceptance criteria, and open questions.

## Boundaries
Produces a REQUIREMENTS SPEC ONLY — no architecture diagrams, no code (use `/sc:design` or `/sc:implement` next). Doesn't override the user's vision with a prescriptive solution during exploration.
