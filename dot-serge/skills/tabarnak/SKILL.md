---
name: tabarnak
description: Autonomous story-by-story build loop (ported from snarktank/ralph, MIT; renamed tabarnak) — drives a prd.json through repeated FRESH serge sessions, one story per iteration; a story's box is checked only when its deterministic test command exits 0. progress.txt carries learnings across iterations. The feature-flow doctrine, automated.
whenToUse: Use when the user wants a whole multi-feature product built autonomously from a PRD ("build all of this", "work through the backlog overnight"), or asks for tabarnak by name. NOT for single features (do those inline) or for tasks without testable acceptance criteria — write the PRD with per-story test commands first.
---

# Tabarnak — the PRD loop

`~/.serge/skills/tabarnak/tabarnak.sh --prd prd.json [--dir .] [--max 10] [--same-fail-cap 3]`

## Why fresh context per story
Long build sessions rot: the model drags stale assumptions and half-done threads
forward. Tabarnak spawns a NEW serge session per iteration — each sees only the repo,
one story, and `progress.txt` (append-only learnings). Right-size stories to fit
one context window.

## The runner owns the truth
- `prd.json` story: `{"id", "priority", "story", "acceptance", "test", "passes"}`.
  The `test` field is a shell command; **the runner sets `passes: true` only when
  it exits 0** — the model's claim is never trusted (same doctrine as the F.3
  stop gate). A story with no `test` refuses to run.
- Passing stories get a git commit each (`tabarnak: story <id> passes its gate`).
- Same story failing its gate 3× consecutively ⇒ loud stop (a blocker, not a
  retry-forever). `TABARNAK.STOP` in the project dir stops gracefully.

## Worked example
```json
{ "stories": [
  { "id": "s1", "priority": 1,
    "story": "CLI `todo add <text>` appends a todo line to todos.txt",
    "acceptance": "running `./todo add buy-milk` twice yields two lines",
    "test": "./todo add x && ./todo add y && [ $(wc -l < todos.txt) -ge 2 ]",
    "passes": false },
  { "id": "s2", "priority": 2,
    "story": "`todo list` prints numbered todos",
    "acceptance": "output contains '1.' and the first todo text",
    "test": "./todo list | grep -q '1\\.'",
    "passes": false }
] }
```

## Cost/safety on this box
Each iteration is a full headless serge run (`--yolo`, bench env): free seats
first, paid last rung under the $3/day/$20-month watchdog. Default `--max 10`
bounds a runaway; size `--max` to the story count. Write the PRD with the
`prd`-style granularity: one deployable, testable slice per story.

## Anti-patterns
- Stories without a deterministic `test` ("make it nice") — the gate can't gate.
- One giant story ("build the app") — defeats fresh-context right-sizing.
- Editing `prd.json` from inside a story session — the runner owns that file.
