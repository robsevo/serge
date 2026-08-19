---
name: learn
description: Read and learn a batch of code, then persist a concise architecture digest to Serge's memory
---

# Learn this code

Absorb the batch of code identified below and persist what matters, so future sessions start already knowing it instead of re-deriving it.

Target: `$ARGUMENTS` — a path, glob, module, or area. If empty, the current repository.

1. **Map it.** Identify the files in scope. For a large or unfamiliar batch, delegate the read-heavy discovery to one or more scout subagents (per the constitution's `## delegation` rules) so the raw file dumps don't crowd your context — keep the conclusions and the `file:line` refs, not the dumps. For a small batch, read it directly.
2. **Synthesize a tight digest** — high-signal, not a file-by-file dump: the batch's purpose, its architecture and layout, the key modules and entry points, the conventions and patterns it follows, the main data/control flow, and any gotchas or non-obvious constraints. Ground every claim in something you actually read (`file:line`), per `## accuracy` — do not guess at structure you haven't seen.
3. **Persist it to memory.** Following the constitution's `## memory` rules, write a concise digest to `~/.serge/memory/<short-kebab-slug>.md` (e.g. `codebase-<area>.md`) with frontmatter (`name`, `description`, `type: project` or `reference`, and a real `source`: the paths read + today's date), then add a one-line index entry to `~/.serge/memory/MEMORY.md` under `## Facts`. Keep it compact — one digest file, high-signal. If the store is near its ~100-fact cap, prune the stalest entry first. Do not paste large code blocks or anything trivially reconstructable from the repo; capture the understanding, not the source.
4. Confirm in one or two lines what you learned and where you saved it, then stop.
