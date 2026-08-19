# Serge loops — "I don't prompt Claude anymore; I write loops."

Autonomous outer loops that prompt serge headlessly on triggers, so the human
feeds queues and reviews results instead of typing prompts. Every loop follows:

    trigger → guards → build_prompt() (sensor) → serge -p --yolo (bounded)
            → tripwire → journal → post_run() (actuator)

## The loops

| loop      | trigger                              | what it does |
|-----------|--------------------------------------|--------------|
| eval-gate | nightly 03:30 (`serge-loop@eval-gate.timer`) | runs the golden-task gate; on regression, diagnoses, writes `findings-<date>.md`, proposes (never applies) constitution fixes |
| err-triage| `serge-query-errors.log` grows (`serge-loop@err-triage.path`) | classifies new errors vs known interrupt causes → `triage-inbox.md`; new signatures get a draft memory note for human promotion |
| backlog   | hourly `serge-loop@backlog.timer` (ships **disabled**; run manually first) | drains one `- [ ]` item from an enrolled project's BACKLOG.md in an isolated worktree on branch `loop/<slug>`; tests gate the ✔ |

Also part of the loop story (inner loops, wired in settings.json):
`continue-on-unfinished.sh` (anti-stall), `stop-checks.sh` (verify → review →
eval-gate on every Stop, which also feeds `reflexion-log.jsonl`), and the
budget watchdog timer ($10/day OpenRouter backstop for the paid seats — the
hive itself is free-tier; if `monitor/.budget-capped` appears, loops stand
down until UTC midnight or `serge --uncap`).

## Daily use (the human's new job)

- **Feed work**: add `- [ ] item` lines to an enrolled project's `BACKLOG.md`
  (sub-bullets = acceptance criteria). Enroll projects in
  `backlog/projects.conf` (`path|test cmd|base branch`).
- **Morning review**: your next serge session surfaces pending items from
  `~/.serge/NOTIFICATIONS.md` automatically (notifications-load.sh). Check off
  handled lines (`- [x]`). Review `loop/<slug>` branches → merge or discard;
  failed attempts keep their worktree under `backlog/worktrees/` for autopsy.
- **Promote knowledge**: err-triage drafts memory notes in its
  `triage-inbox.md`; promote the good ones via `/remember`. eval-gate writes
  constitution proposals to `~/.serge/constitution-proposals.md`; apply by hand
  (the eval gate re-checks you).
- **Manual kick**: `~/.serge/loops/run-loop.sh <name> --now` (bypasses only
  the per-loop daily cap).
- **Watch**: `tail <name>/journal.jsonl` (one JSON line per run: outcome, cost,
  turns), `<name>/last-run.json`, `<name>/stderr.log`,
  `systemctl --user list-timers 'serge-loop*'`.

## Kill switches & rails

- `touch ~/.serge/loops/DISABLED` — all loops off. Per-loop: `<name>/DISABLED`.
  Env: `SERGE_LOOPS_DISABLE=1`.
- Per-loop `LOOP_MAX_RUNS_PER_DAY` + global `SERGE_LOOPS_GLOBAL_MAX_PER_DAY`
  (default 100/day) + `--max-turns` + `--max-budget-usd` + `timeout(1)` per run.
- **Tripwire**: if a run coincides with any change to CONSTITUTION*/council/
  agents/commands, ALL loops hard-disable and you get notified. Loops may only
  ever *propose* brain changes.
- Backlog never touches your checkout: all git is deterministic harness code;
  work lands on `loop/<slug>` branches; `[x]`/`[!]` annotations are committed
  on the branch; a ledger (`backlog/state/done.jsonl`) prevents re-picking.
  `[!]` items are never auto-retried — reset to `- [ ]` after review.

## Sharp edges (learned the hard way)

- The serge wrapper sources `serge.env` with `set -a`, which **clobbers env you
  export**. Loop knobs must go through `serge-loop.env` / per-loop `LOOP_ENV`
  (run-loop.sh merges them into `state/run.env` and passes `SERGE_ENV_FILE`).
- Loops call `~/.local/bin/serge` (the wrapper), never `serge-resume`, and
  redirect `SERGE_STOP_FAILURE_SENTINEL` loop-locally so a loop failure can't
  make your next interactive session auto-resume something weird.
- The prompt is passed as the FINAL positional arg so
  `SERGE_LOOP_BIN="node ~/.serge/evals/tests/stub-serge.mjs"` gives $0 dry runs.

## Adding a loop

    mkdir -p ~/.serge/loops/<name>
    $EDITOR ~/.serge/loops/<name>/loop.conf   # define build_prompt() (+ post_run())
    ~/.serge/loops/run-loop.sh <name> --now   # test it
    # then add a serge-loop@<name>.timer (or .path) in ~/.config/systemd/user

Contract: build_prompt() writes the prompt to `$PROMPT_FILE`; return 3 = quiet
"nothing to do" ($0); it may set LOOP_CWD/LOOP_MODEL per run. post_run() gets
(rc, result-json-path) and commits state — offsets/ledgers advance only on
success so failures retry naturally on the next trigger.
