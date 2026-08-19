---
name: resilient-external-calls
description: Make every network/subprocess/external call time-bounded, and correctly tell a hung-script kill apart from a real API/model interrupt before fixing the wrong thing.
whenToUse: Use when writing or reviewing code that calls the network (fetch/http/axios), spawns subprocesses, or runs a long pipeline/script — anything that waits on something external. ALSO use when triaging a stall or interrupt: a command that hangs, gets killed, exits 137, or shows "[Request interrupted]" — to decide whether it's a script/tool hang or an actual API/model failure.
---

# Resilient external calls & interrupt triage

Two tightly-linked lessons learned the hard way (example-web link-freshness pipeline, 2026-06-27).

## 1. Every external call must be time-bounded

An external call with no timeout can wait **forever**. The classic failure: a bare
`fetch(url)` against a host that holds the socket open (rate-limiting, a dead box that
accepts the connection but never responds). The call never returns, so a retry/backoff
loop *above* it never runs, and the whole script stalls until something kills it
(SIGKILL → exit 137). It looks like a freeze or an "interrupt"; it's an unguarded wait.

When writing or reviewing code that waits on something external, require a timeout on
**every** such call — not just the ones that failed today:

- `fetch`: `fetch(url, { signal: AbortSignal.timeout(15000) })` (or an `AbortController`
  + `setTimeout(() => controller.abort(), ms)` then `clearTimeout`). A try/catch around
  it turns the abort into a normal, retryable error.
- Other clients: set connect AND read timeouts (axios `timeout`, Python `requests`
  `timeout=`, etc.) — a connect timeout alone still hangs on a stalled read.
- Subprocesses / shell: cap them (`timeout <s> <cmd>`, a spawn kill-timer) so a child
  that wedges can't wedge the parent.
- Long pipelines: bound each stage, and make a single slow/dead upstream **fail fast
  and get skipped/logged**, not block the run. Pair the timeout with bounded retry +
  backoff so a transient stall recovers instead of aborting the whole job.

Audit the WHOLE file/pipeline, not only the line that hung — fixing one fetch while
three siblings stay unguarded just moves the hang.

### 1a. Some calls fail WITHOUT rejecting — wrap the promise, not just the call

A per-call timeout (`AbortSignal.timeout` / try-catch) only helps if the failure
arrives as a rejection. It sometimes doesn't: a malformed response can trip an
assertion deep in **Node's undici HTTP parser** that surfaces as a process-level
`uncaughtException` instead of rejecting the fetch — so `await fetch(...)` (and its
abort timer) never settles. The promise stays pending forever; `Promise.all` over a
batch hangs on it; and once no timers/handles remain the process can **exit before
your pipeline finishes writing its output** (looks like "ran fine, produced nothing").
Seen for real: example-web link-freshness nightly, 2026-06-28 — first GitHub run verified
0 channels and skipped deploy because of exactly this.

Defenses (use both):
- **Wrap the whole promise in an outer timeout** that resolves to a safe fallback, so a
  never-settling call can't stall its batch or the run:
  `Promise.race`-style — `withTimeout(p, ms, fallback)` = a `setTimeout(() => resolve(fallback), ms)`
  alongside `p.then(resolve, () => resolve(fallback))`. The timer also keeps the event
  loop alive so the process can't exit early. Apply it to every fetch-heavy stage
  (download AND verify), not only the one that hung.
- Add a process-level `uncaughtException` / `unhandledRejection` handler that **logs and
  continues** — a single bad response must never kill a long batch job. (It's a backstop,
  not the fix: the diverted error still leaves the original promise pending, which is why
  the outer `withTimeout` is what actually unblocks the batch.)

## 2. Triage a stall/interrupt before "fixing" it

Don't assume an interrupt is the model or the API. Identify the class from evidence
first, because the fix lives in completely different places:

**Script/tool hang or kill** (the common false alarm) — signs:
- Tool result shows a non-zero **exit code, especially 137** (SIGKILL, often after a
  long wait) or 124 (a `timeout` wrapper firing).
- The transcript labels it **"[Request interrupted by user for tool use]"** and the
  last visible output is stuck mid-stage.
- Serge's query-error diagnostic log is **empty** (no exception was thrown in the model
  loop). → This is a hang in the *command*, not an API failure. Fix the script
  (add the timeout per §1); do NOT touch the model/router/transport.

**Real API/model interrupt** — different signs: an actual "API Error" / "Please wait"
message, an `isApiErrorMessage` record with an `error` type, a non-200 in the router
log, or a thrown exception captured in the diagnostic log. → Now it's the
transport/router/budget layer; debug there.

Quick checks: read the tool result's exit code; read the transcript tail for the
interrupt label and last output; check the router/litellm log for a non-200; check
whether any diagnostic/error log actually recorded an exception. Match the fix to the
class — patching the API path for a script hang (or vice-versa) burns effort and
leaves the real bug live.

## 3. Running long commands without getting Esc'd

A foreground command that runs longer than the Bash default timeout gets killed
mid-run and looks "stuck", which is what makes a watching user hit Esc (the
"Interrupted — what should I do instead?" prompt is that Esc; it is NOT an error and
nothing can override a genuine user stop). Avoid the situation:

- For a command whose result you need *now* but that may take a while (a build, a test
  suite, a multi-stage pipeline like `npx tsx …`), give it an explicit generous
  `timeout` rather than relying on the default. Serge's default is 5 min
  (`BASH_DEFAULT_TIMEOUT_MS`); a longer job needs an explicit value.
- For a genuinely long or open-ended job (a dev server, a full verify run, a watch),
  use **`run_in_background`** and get notified on completion instead of blocking the
  turn — don't sit in the foreground looking hung.
- Surface progress for slow stages (stream/log it) so a watching user can see it's
  working, not frozen.

And when a command you ran **fails** (non-zero exit — this is a normal error result you
receive, not an interrupt): investigate the cause and continue the task. Read the error
output, form a hypothesis, fix it — do not narrate "that failed" and end the turn
handing the problem back. Ending the turn on a self-inflicted command error is the
stop-short failure mode; the error output is exactly the evidence needed to proceed.
