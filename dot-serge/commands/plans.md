---
name: plans
description: Browse, summarize, reopen or delete shelved plans from previous sessions
allowed-tools: Bash($SERGE_HOME/plans-list.sh:*)
argument-hint: "[number|name] [summarize|delete]"
---

# Shelved plans

Every plan Serge writes is kept in `~/.serge/plans/`. Only the most recent
approved one reaches `plan.md`; the rest sit on the shelf. This command reopens
them.

## 1. Show what's on the shelf

Run `$SERGE_HOME/plans-list.sh` (add `--all` if the user asks for older
ones, or if `$ARGUMENTS` suggests they're looking for something not in the
recent set).

Present the list plainly: number, date, title. Don't editorialise and don't
summarise plans you haven't read — the titles are the index, not your guess at
what each contains.

If `$ARGUMENTS` already names a plan (a number, or words matching a title), skip
straight to step 2 with that selection. Otherwise ask which one they want.

If the user only wants to look, not decide, go to **3a** rather than **3**.

## 2. Load the chosen plan

Run `$SERGE_HOME/plans-list.sh --show <n-or-name>`.

If it reports the selection is ambiguous, show the candidates it listed and ask
which — do not pick one yourself.

Read the plan, then give the user a **short** orientation before asking anything:

- **What it does** — two or three lines, in your own words.
- **When it was written** — and, if the plan's assumptions look stale relative
  to the current state of the repo, say so plainly. A plan written three weeks
  ago may reference files or decisions that have since changed. This is the one
  place you should be sceptical rather than agreeable.
- **What it would touch** — the files or areas involved, if the plan names them.

## 3a. Summarise instead, when that's what they want

If the user asked to *summarise* a plan — `/plans summarize 3`, "just give me
the gist of 3", or anything else that reads as wanting to look rather than
decide — take this path and **not** the yes/no one below.

Run `$SERGE_HOME/plans-list.sh --outline <n-or-name>` first. It prints
the real heading structure, the step count and the files the plan names, for no
model cost. Read the full plan with `--show` only if the outline leaves the
substance unclear.

Then give a summary in two parts, both grounded in what the plan actually says:

- **Phases** — the plan's own stages, in order, one line each on what that phase
  achieves. Use the plan's phase names where it has them (most do). If it has no
  phases, say so and give the natural stages instead of inventing labels.
- **Features** — what the plan actually delivers, as capabilities rather than
  edits. "Source health is checked in parallel instead of serially" is a
  feature; "modifies useStreamCheck.ts" is not. Note where each lands if the
  plan says.

Then add at most one line if something genuinely warrants it — a stale
assumption, a phase already done, a conflict with what the user said today.
Skip it if there's nothing real to flag.

**Stay in plan mode.** Do not call ExitPlanMode, do not adopt the plan, do not
write `plan.md`, do not start any of the work, and do not create a new plan off
the back of it.

**Do not end with a question.** No "shall I proceed?", no "would you like me
to…", no menu of options. The user asked to see the plan, not to be asked about
it. Stop after the summary and wait — they'll say what they want next, and it
may well have nothing to do with this plan.

## 3. Ask, then respect the answer

Ask exactly one question:

> Proceed with this plan? (yes / no)

Then stop and wait. Do not begin any of the work, do not adopt the plan, and do
not start "just the first step" while waiting.

### If yes

1. Run `$SERGE_HOME/plans-list.sh --adopt <n-or-name>` — this copies the
   plan to `plan.md` at the repo root, the same place the plan-mode hook writes,
   so the rest of the tooling picks it up normally. It backs up any different
   `plan.md` already there and tells you where.
2. Say which plan is now active and what the first concrete step is.
3. Begin executing it.

### If no

**Do not adopt it and do not execute it.** The plan stays on the shelf exactly
as it was.

Instead, talk it through against what the user actually asked for. They opened
this plan for a reason and declined it for a reason, and the second one is the
useful one. Work out which it is:

- The plan solves a problem they no longer have → say what changed, and ask what
  they want instead.
- The plan is roughly right but wrong in specifics → name the parts that survive
  and the parts that don't, and propose the amendment.
- The plan conflicts with something they've said in this session → quote both,
  and ask which one wins.
- They're comparing several shelved plans → offer to show another rather than
  re-litigating this one.

Use what the user has said **in this conversation** as the reference point, not
the plan's own framing. The plan is a proposal from a past session; the user's
current intent outranks it.

End by asking what they'd like to do — amend it, look at a different plan, or
start fresh. Don't write a replacement plan unless they ask for one.

## Deleting, at any point

The user can clear plans off the shelf while browsing — including plans they
just declined. Run
`$SERGE_HOME/plans-list.sh --delete <n-or-name>`; several at once is
`--delete 3,7,12`.

Two things to know, and to tell them if it matters:

- It moves the plan to `~/.serge/plans/.trash/` rather than deleting it, so a
  wrong number is recoverable. Trash prunes itself after 30 days.
- Selections are resolved **before** anything moves, and if any one of them
  doesn't match, nothing is deleted at all. So a typo in a list is safe.

Confirm the titles before deleting more than one, since numbers are easy to
mistype — read back what you're about to remove, then do it. Don't re-ask for
confirmation on a single obvious deletion the user just named; that's friction,
not safety.

Never delete a plan the user hasn't asked you to, and never "tidy up" the shelf
on your own initiative.
