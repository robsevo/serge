---
name: recap
description: Read what just happened (terminal scrollback, router/system logs, recent session) so Serge can troubleshoot a stop or failure
allowed-tools: Bash($SERGE_HOME/recap.sh:*)
---

# Recap & troubleshoot

Run `$SERGE_HOME/recap.sh` to gather three context sources: tmux terminal scrollback (if running in tmux), the serge-router + system logs and budget state, and the most recent session transcript for this project.

Then read that output and tell the user, concisely and grounded in the actual log/transcript evidence — never invented:

1. **What happened** — a short narrative of the recent activity / what scrolled past above.
2. **Anything wrong** — errors, a stopped router, a hit budget cap, OpenRouter `402`/credit-limit rejections, `finish_reason=error` stalls, timeouts, or other failures. Quote the real error line, don't paraphrase it away.
3. **Why** — the root cause, traced from the evidence (not a guess). If the evidence is ambiguous, say so.
4. **Fix** — the concrete next step (e.g. restart the router, add OpenRouter credits, re-arm or pause the budget watchdog, reduce context size, lower `max_tokens`).

If a source was unavailable (e.g. not in tmux, or no transcript dir), say so in one line rather than inventing what it would have shown. If `$ARGUMENTS` names something specific to focus on, prioritise that.

$ARGUMENTS
