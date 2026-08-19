---
name: skill-authoring
description: How to create, structure, and iterate on serge house skills — SKILL.md anatomy, progressive disclosure, description-triggering that actually fires, bundled scripts/references, and an eval loop using serge's own harness. Includes a scaffolding/validation script.
whenToUse: Use whenever creating a new skill, editing or restructuring an existing one, or when a skill exists but never triggers / triggers at the wrong times. Also when turning a workflow that just happened in conversation into a reusable skill ("make this a skill").
---

# Skill authoring — house rules

A skill is a folder in `~/.serge/skills/<name>/` with a `SKILL.md` and
optional bundled resources. Scaffold + validate with
`scripts/init_skill.py <name>` (also validates existing skills:
`--validate-only <path>`).

## Anatomy

```
skill-name/
├── SKILL.md          required — frontmatter + instructions
├── scripts/          executable code for deterministic steps (plain python3,
│                     stdlib-preferred, IPv4-forced for HTTPS on this box)
├── references/       docs loaded into context only when needed
└── assets/           files used in output (templates, themes, fonts)
```

House frontmatter has THREE fields — `name`, `description` (what it does),
and `whenToUse` (when to fire). Keep all triggering language in the
frontmatter, not the body.

## Progressive disclosure — the whole design constraint

1. **Frontmatter** loads into EVERY session (~100 words) — it pays rent
   every turn, keep it tight.
2. **SKILL.md body** loads when the skill triggers — under ~500 lines; near
   the limit, push detail down a level with clear pointers.
3. **Bundled resources** load only when followed — unlimited; scripts can
   run without ever being read into context.

Organize multi-domain skills by variant (`references/aws.md`,
`references/gcp.md`) so only the relevant file gets read. Give big reference
files a table of contents.

## Descriptions that trigger

Models under-trigger skills. Make `whenToUse` a little pushy: name the
concrete user phrases and situations that should fire it ("use whenever the
user mentions X, Y, Z — even if they don't say the word 'skill'"), and name
what it must NOT fire for. Vague purpose-statements never trigger.

## Process for a new skill

1. **Capture intent.** If the conversation already contains the workflow
   ("turn this into a skill"), extract steps/tools/formats from history
   first, confirm gaps. Otherwise pin down: what should it enable? what
   phrases trigger it? expected output format? edge cases and dependencies?
2. **Draft** — imperative voice, tables over prose walls, concrete commands
   over descriptions of commands. Deterministic/repetitive steps become
   scripts; long context becomes references; SKILL.md stays the map.
3. **Validate structure**: `init_skill.py --validate-only <path>`.
4. **Test it fires and works.** Run 2-3 realistic prompts through a fresh
   serge session; watch whether the skill triggers at all (frontmatter
   problem) and whether following it produces the right output (body
   problem). Fix the failing layer, not the other one.
5. **Regression-guard** what matters: skills with objectively checkable
   output deserve a golden task in `~/.serge/evals` (run.mjs baseline/gate),
   like eval task 10 guards frontend quality. Subjective-output skills
   (style/art) usually don't need one.
6. **Sync the mirror** — every serge change ends with
   `~/programs/serge-portable/sync-portable.sh`.

## House conventions the scaffolder enforces

- kebab-case name matching the directory; frontmatter `name` identical.
- All three frontmatter fields present and non-empty; body non-trivial.
- Any HTTPS-calling python script forces IPv4 (`socket.getaddrinfo` patch)
  and time-bounds every call (see `resilient-external-calls`).
- Vendored/adapted third-party content keeps its license file in the skill
  dir + one attribution line at the SKILL.md bottom (mirror is shareable).

---
*Distilled from [anthropics/skills](https://github.com/anthropics/skills)
`skill-creator` (Apache-2.0 — see LICENSE.txt); eval loop re-pointed at
serge's own harness instead of the bundled claude-cli machinery.*
