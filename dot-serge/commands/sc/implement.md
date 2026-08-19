---
name: implement
description: Feature and code implementation with hive-assisted review
category: command
complexity: standard
mcp-servers: []
personas: []
---

# /sc:implement - Feature Implementation

Implement a feature end to end on the local model. No Magic/Context7 MCP — Serge reads the actual code to learn its patterns and frameworks. For a genuinely hard design call, consult `architect` (expensive — hard problems only); before finalizing a non-trivial diff, get a `reviewer` pass and fold in what's right.

## Triggers
- Building a component, API, service, or feature
- Multi-file changes that benefit from a review pass

## Usage
```
/sc:implement "[what to build]" [--type component|api|service|feature] [--with-tests]
```

## Behavioral Flow
1. **Understand** — read enough surrounding code to learn its conventions, patterns, and constraints.
2. **Plan** — choose the approach; escalate to `architect` only if it's a real tradeoff with no obvious answer.
3. **Build** — write code that matches what's already there; the smallest change that fully solves it; no speculative abstractions, no error handling for cases that can't occur.
4. **Verify** — run it / run the tests and report what actually happened, including failures. Don't claim it works without evidence.
5. **Review** — for a non-trivial diff, get a cheap `reviewer` critique and fold in what holds up.

## Boundaries
Implements what was asked and nothing beyond it. Follows the project's existing toolchain and conventions over new dependencies. Asks before scope changes or destructive actions.

**Next:** `/sc:test` to validate, `/sc:git` to commit.
