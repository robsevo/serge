# Contributing to Serge

Thanks for considering it. This document is short and specific, because Serge is
an unusual repository and the usual advice does not all apply.

## Read this first: what lives here

This repo is the **brain** — hooks, subagent definitions, skills, slash commands,
the router config, service units, the installer. It is not the CLI engine. See
README §2.

That has a practical consequence for contributors: **almost every behaviour you
might want to change is a shell script here, not engine code you don't have.**
Before proposing an engine change you cannot make, check whether a hook can do
it. Most of Serge's behaviour is hooks, and a hook takes effect on the next
prompt with no build step.

## The one convention that matters: `WHY` blocks

Every hook opens with a comment explaining the **specific failure it prevents**,
ideally with the date and the observed symptom. Not what the code does — the code
says that. Why it exists at all.

```bash
#!/usr/bin/env bash
# PostToolUse hook — refuse edits to paths that don't exist.
#
# WHY: on 2026-07-29 the agent wrote a file to a directory it had invented,
# and Write silently created the parent, so nothing failed and the mistake
# only surfaced two turns later.
```

This is not decoration. These preambles are the highest-value documentation in
the repo: they are a list of the ways an agent actually goes wrong. A hook
without one will be asked to add one. If you cannot name the failure it prevents,
that is a strong signal the hook should not exist.

## House rules

- **Fail open.** A hook that cannot do its job must exit 0 and get out of the
  way. A broken guard must never be able to block a turn. `command -v python3
  >/dev/null || exit 0` at the top is the normal shape.
- **Never block on infrastructure.** Provider errors, missing tools and unparsed
  JSON are not the user's fault. Advise, don't deny.
- **Cheap checks first.** If a hook chain has a mechanical check and a model
  call, the mechanical one runs first and can short-circuit. Model calls cost
  the user real quota.
- **Guard the pipeline, not one stage.** If a condition means "skip the checks"
  (a user interrupt, for example), it belongs before every stage, not inside the
  first one.
- **A skill's directory name must equal its `name:` frontmatter.** The loader
  matches on it.
- **No secrets, ever.** Keys live in `router.env` / `serge.env`, both `chmod
  600`, both git-ignored, neither shipped. Nothing else may read them.

## Testing a change

There is no build step for the brain. Hooks are executed by the engine with a
JSON payload on stdin, so you can drive them directly:

```bash
# a Stop hook
printf '{"session_id":"t","last_assistant_message":"done","cwd":"/tmp"}' \
  | bash dot-serge/stop-checks.sh; echo "exit=$?"

# a UserPromptSubmit hook
printf '{"prompt":"refactor the parser","cwd":"/tmp"}' \
  | bash dot-serge/complexity-directive.sh
```

Check all four of these before opening a PR:

1. `bash -n` parses your script.
2. It exits 0 on an empty/garbage payload.
3. It exits 0 when its dependencies are missing.
4. It does what it claims on a payload that *should* trigger it — include that
   payload in the PR description.

The installer can be exercised safely against a throwaway home:

```bash
HOME=$(mktemp -d) ./install.sh --engine /path/to/engine --dry-run
```

Never run `install.sh` against your real `$HOME` to test it: it writes
`~/.serge` and drops service units.

## Pull requests

Keep them to one concern. Say what failure the change prevents and how you
verified it — an actual command and its output, not "tested locally". If you
changed a hook, include the payload you drove it with.

Serge does not add itself as a co-author to commits, and contributions are not
expected to either.

## Model seats

`dot-serge/litellm.yaml` is the roster, and its comments record why each seat
exists — including expensive mistakes. If you change a seat, update the comment
with what you measured. A roster claim without evidence behind it is how the
whole thing rots: a seat can return HTTP 200 while a completely different model
answers, so "it worked" is not evidence. `seat-health.sh` is.
