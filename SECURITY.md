# Security Policy

## Reporting a vulnerability

Please report privately, not in a public issue.

Use GitHub's **"Report a vulnerability"** button under this repository's
*Security* tab, which opens a private advisory visible only to maintainers.

Please include the affected file, what an attacker can achieve, and the smallest
input that demonstrates it. If a fix is obvious, say so — most issues here will
be a few lines of shell.

## What is in scope

This repository ships **shell scripts that the agent's engine executes
automatically** on lifecycle events, plus a router config and an installer.
The interesting attack surface is therefore:

- **Hook scripts** (`dot-serge/*.sh`, `dot-serge/hooks/*.sh`) — these run on
  every turn with your user's privileges. Command injection through a hook's
  JSON payload, or through file contents a hook reads, is in scope.
- **The installer** (`install.sh`) — it writes `~/.serge`, rewrites paths, and
  installs service units.
- **Skill and agent definitions** that direct the agent toward unsafe commands.
- **The router config** (`dot-serge/litellm.yaml`) — anything that could route a
  request, or a credential, somewhere unintended.

## What is out of scope

- **The CLI engine.** It is not in this repository and not ours to patch — see
  README §2. Report engine issues to whoever publishes your engine.
- **Model output.** An agent that writes bad code is a quality problem, not a
  vulnerability. An agent that can be steered into exfiltrating your keys is a
  vulnerability — please report that.
- **Upstream model providers.** Report those to the provider.

## How credentials are handled

Worth stating plainly, because it is the question people ask:

- Keys live in `~/.serge/router.env` and `~/.serge/serge.env`, created at mode
  `600` by the installer.
- Both are listed in `.gitignore`, and **only blanked `.template` files are
  distributed** — this repository has never contained a key.
- The build that produces this repo runs a leak gate that fails on key-shaped
  strings, non-blank env values, and personal identifiers, and a completeness
  gate that runs first so an empty build cannot pass by having nothing to find.
- Keys are read by the local router process. Hooks do not read them, and no hook
  should ever need to. A change that makes a hook read a credential file will be
  treated as a security regression.

## Hardening notes for operators

- Serge sets `CLAUDE_CONFIG_DIR=~/.serge`, so it does not share configuration
  with a stock Claude Code install on the same machine.
- Autonomous loops (`serge-loop@*`) ship **disabled**. Read
  `dot-serge/loops/README.md` before enabling one; a loop pointed at the wrong
  directory is the most expensive mistake available here.
- Bypass/auto-approval modes exist and are off by default. Turning them on means
  the agent runs commands without asking — appropriate for a sandbox, not for a
  machine holding credentials you care about.
- Free model tiers may train on your inputs. Do not route secrets through them.
