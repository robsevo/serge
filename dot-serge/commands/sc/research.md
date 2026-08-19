---
name: research
description: Deep web research with adaptive planning and evidence-based synthesis
category: command
complexity: advanced
mcp-servers: []
personas: []
---

# /sc:research - Deep Research

Conduct multi-source web research and produce a cited, evidence-based answer. Uses Serge's native WebSearch and WebFetch tools (no MCP). For broad fan-out gathering in an unfamiliar area, delegate to the `scout` subagent.

## Triggers
- Questions beyond the training cutoff; current events; real-time info
- Multi-source technical, academic, or market research

## Usage
```
/sc:research "[query]" [--depth quick|standard|deep]
```

## Behavioral Flow
1. **Scope** — assess the query; define what a complete answer actually needs.
2. **Plan** — break it into sub-questions; note which searches are independent (batch those).
3. **Search** — run independent WebSearch queries in parallel; WebFetch full pages when snippets are thin; follow entity/concept chains for depth.
4. **Verify** — cross-check claims across sources; flag contradictions and uncertainty; never assert beyond the evidence or invent a citation.
5. **Answer** — lead with the finding, then the supporting evidence with sources.

Depth: quick = ~1 hop, summary · standard = 2–3 hops, structured · deep = 4–5 hops, thorough.

## Boundaries
Produces a RESEARCH ANSWER/REPORT ONLY — no implementation, no code, no system changes. Every claim is sourced; if it can't be sourced, say so plainly. Save longer reports to `claudedocs/research_[topic].md`.

**Next:** the user decides what to do with the findings (`/sc:implement` to act on them).
