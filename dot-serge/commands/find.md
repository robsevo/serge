---
name: find
description: Thorough file + content search — multiple naming conventions in parallel, ranked results, never a premature "not found"
---

# Find — locate files, symbols, or content anywhere in the project

Locate what $ARGUMENTS names. If $ARGUMENTS is empty, ask what to find. This is a deterministic sweep with the native Grep/Glob tools — no subagents, no model seats, no cost beyond the turn itself.

1. **INTERPRET** — decide what kind of thing the query names: a file, a symbol (function/class/flag), a concept/feature, or a literal phrase. Then derive the search variants BEFORE searching: kebab-case, snake_case, camelCase, PascalCase; singular and plural; the word stem and its common expansions (auth → authenticate, authorization; config → configuration); known abbreviations. A query names an idea, not a spelling — the repo may use any of these.

2. **SWEEP** — run the passes as parallel tool calls in one step, not one-by-one:
   - *Filename pass*: Glob `**/*<variant>*` for each naming variant.
   - *Content pass*: Grep each variant case-insensitively; for a symbol, also grep definition shapes (`function <name>`, `class <name>`, `const <name>`, `def <name>`, `<name> =`).
   - *Config/docs pass*: when the term looks like a setting, env var, or feature name, grep `*.json`, `*.yaml`, `*.toml`, `*.env*`, `*.md` too — features often live in config before they live in code.

3. **RANK** — order what came back: exact filename match, then definition site, then live references, then docs/config mentions. Present a short ranked list with clickable `file:line` refs and one line of context each — never a raw grep dump. If one result is clearly the answer, open it and confirm.

4. **NEVER QUIT ON THE FIRST MISS** — an empty result means the variants were wrong, not that the thing is absent. Broaden once: split compound words, try a different stem, `ls` the likeliest directories to learn this repo's actual naming convention, then re-sweep with what that teaches. Only after that, report not-found — and list exactly which variants and passes were tried, so the user sees what "not found" is based on.

$ARGUMENTS
