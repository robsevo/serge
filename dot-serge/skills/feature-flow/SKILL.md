---
name: feature-flow
description: The build-and-troubleshoot discipline — a product is a host of features, and every feature runs BRAINSTORM → PLAN → BUILD → TEST → CONFIRM before the next one starts. Includes the surface-by-surface (A-Z) troubleshooting sweep, hunting swallowed errors / unbounded fetches / silent defaults, and end-to-end verification by driving the real app rather than reasoning about it.
whenToUse: Use whenever building a feature, shipping a change, or troubleshooting a product — "build X", "add X", "fix X", "why is X broken", "it hangs/doesn't load/shows nothing", a bug sweep, a QA pass, or planning a multi-feature push. Load it BEFORE writing code or forming a diagnosis, and re-read it when tempted to declare something done without running it.
---

# Feature flow — how work actually gets finished

## The unit of work is the FEATURE

**A product is a host of features. A feature is the unit — never "the whole thing at once."**

Every feature runs the full cycle, in order, before the next one starts:

```
BRAINSTORM → PLAN → BUILD → TEST → CONFIRM
```

- **BRAINSTORM** — what is actually being asked, who it's for, what "done" means, what could go
  wrong. Surface the ambiguity here, not after building the wrong thing.
- **PLAN** — the concrete approach: which files, which functions, what changes in each, the
  ordered steps, the edge cases, how it will be verified. Written down, not held in your head.
- **BUILD** — implement it completely. No TODOs on core behavior, no stubs, no "I'll wire it up
  when I do the next one."
- **TEST** — write and run its tests. Validation, ranges, known-answer, edge cases, integration.
- **CONFIRM** — verify it works **in the real thing** (see end-to-end below), then say plainly
  what was verified and what wasn't.

**One feature at a time. Finish it completely before starting the next.** No feature is left
"mostly done." A feature is not done because the code exists — it is done when it is built,
tested, and confirmed running.

## Troubleshooting: surface by surface, A–Z

When something is broken (or before shipping), sweep **one surface at a time, in order, skipping
nothing**. A surface is a screen, an endpoint, a job, a CLI command, a data path.

1. **Enumerate the surfaces first** — write the list before touching anything. You cannot say
   "it works" about a product whose surfaces you never listed.
2. **Take them in order.** Don't jump to the interesting one. The skipped surface is where the
   bug lives.
3. **For each surface**: drive it for real → observe the actual result → only then form a
   diagnosis. One surface fixed and confirmed before moving to the next.
4. **Record per surface**: works / broken (with the exact symptom) / not-yet-tested. "Not tested"
   is an honest state; "probably fine" is not.

## Fail loudly on data gaps

Most "it hangs / it's blank / it silently does nothing" bugs are a swallowed failure. Hunt these
explicitly — they are the splash-hang class:

- **Swallowed errors** — `catch {}`, `catch { return null }`, `.catch(() => [])`, bare `except:`,
  errors logged at debug level and then ignored. Every catch must either handle the failure
  meaningfully or re-raise. A caught-and-dropped error is a bug hiding behind a blank screen.
- **Unbounded fetches / awaits** — any network, subprocess, DB, or IPC call without a timeout
  will eventually hang forever and present as a frozen UI or a stuck job. Bound every one, and
  make the timeout path visible (see the `resilient-external-calls` skill).
- **Silent defaults** — `?? 0`, `|| []`, `.get(k, mean)`, defaulting a missing column to a
  season average. These convert "we have no data" into a confident wrong number. Raise with
  context instead; a loud failure is cheaper than a plausible lie.
- **Missing-state rendering** — a surface that shows nothing when data is absent is
  indistinguishable from one that is broken. Render an explicit empty/error state.

Grep for these directly when diagnosing: `catch\s*{\s*}`, `except:\s*pass`, `\.catch\(\s*\(\)\s*=>`,
fetches without a timeout/signal, and `||`/`??` fallbacks on values that came from I/O.

## Verify end-to-end — drive the real app

**Reasoning about code is not verification.** Confirm by running the real thing:

- Start the actual app/server/job and exercise the actual surface (see the `run` skill; for a web
  UI, drive the browser; for an API, hit the endpoint; for a game, run the playtest harness).
- Assert on observed output — a response body, a rendered element, a file on disk, an exit code —
  not on the fact that the code "looks right."
- Check the failure path too, not just the happy path: what does this surface do when the
  dependency is down, the data is empty, the token is expired?
- **"It works with test data" is not verification.** Use real data / a real run, or say plainly
  that you didn't.
- Changed a boolean condition along the way? An `equiv`/`sat` proof from the `logic` skill's
  `logic_check.py` is part of the verification — eyeballed condition refactors ship behavior
  changes silently.

## Reporting

Say exactly what you verified, how, and what remains unverified. If a step was skipped, say so.
"Built and tested; confirmed running against the live endpoint" and "built, tests pass, NOT yet
run against the real app" are different claims — never blur them.

## Anti-patterns
- Building three features half-way instead of one completely.
- Declaring done at BUILD, skipping TEST/CONFIRM.
- Diagnosing from a code read instead of driving the surface.
- Sweeping only the surface you suspect.
- Fixing the symptom (a default that hides the gap) instead of the swallowed failure underneath.

## Learned the hard way
_Appended automatically as Serge learns; gated by this skill's own tests._
    - Synchronize UI components across all build directories (e.g., /site vs root) before deployment; mismatched paths cause silent rendering failures where the app runs but the UI is broken or missing.
    - Starts with "- "? Yes.
    - States concrete rule? Yes.
    - States WHY? Yes.
