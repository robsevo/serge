#!/usr/bin/env bash
# PostToolUse hook — persist an approved plan to <repo>/plan.md (local, zero token cost).
#
# Fires after ExitPlanMode succeeds (i.e. AFTER you approve "Exit plan mode?").
# Serge already writes every plan to ~/.serge/plans/<slug>.md, but with a random
# per-session slug that a fresh executor session can't find. This hook copies the
# just-approved plan to a STABLE plan.md at the repo root so the cheap executor
# seat can read the plan straight from source next session — "plan high, execute
# cheap." Full plan history still lives in ~/.serge/plans/; plan.md is just the
# current feature's canonical copy and is overwritten each time you approve a new plan.
#
# PRICING: zero token cost on normal turns — this is a local file copy, NOT an LLM.
# The only tokens spent are the one-line systemMessage confirmation shown on the
# (rare) turns where a plan is actually approved.
#
# NEVER blocks: this is a convenience writer, so it always exits 0 (fail-open).
#
# Toggles:
#   SERGE_PLAN_PERSIST_DISABLE=1   turn the hook off entirely
#   SERGE_PLAN_FILE=path           target file (default: plan.md, relative to repo root)
set -u

# --- fail-open guards (never disrupt a turn on infra problems) ---
[ "${SERGE_PLAN_PERSIST_DISABLE:-0}" = "1" ] && exit 0
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0            # don't write inside eval child runs
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

printf '%s' "$input" | SERGE_PLAN_FILE="${SERGE_PLAN_FILE:-plan.md}" python3 -c '
import sys, json, os, datetime

def out(msg):
    # Non-blocking note shown to the user (matches serge hook stdout contract).
    print(json.dumps({"systemMessage": msg}))

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)

if d.get("tool_name") != "ExitPlanMode":
    sys.exit(0)

ti = d.get("tool_input") or {}
tr = d.get("tool_response") or {}
if not isinstance(tr, dict):
    tr = {}

# Skip subagent / teammate plans — plan.md is the MAIN session plan only, and we
# never clobber it with a scratch subagent plan or an unapproved leader request.
if tr.get("isAgent") is True:
    sys.exit(0)
if tr.get("awaitingLeaderApproval") is True:
    sys.exit(0)

# Resolve the plan content. Prefer the normalized tool_input.plan that serge
# injects; fall back to the tool_response, then to reading either file path.
def read_file(p):
    try:
        with open(p, "r", encoding="utf-8") as f:
            return f.read()
    except Exception:
        return None

plan = None
for cand in (ti.get("plan"), tr.get("plan")):
    if isinstance(cand, str) and cand.strip():
        plan = cand
        break
if plan is None:
    for p in (ti.get("planFilePath"), tr.get("filePath")):
        if isinstance(p, str) and p:
            plan = read_file(p)
            if plan and plan.strip():
                break

if not plan or not plan.strip():
    sys.exit(0)  # nothing to persist

# Resolve the project root (serge sets CLAUDE_PROJECT_DIR to the stable repo root).
project = os.environ.get("CLAUDE_PROJECT_DIR") or d.get("cwd") or os.getcwd()
project = os.path.realpath(project)

target_rel = os.environ.get("SERGE_PLAN_FILE") or "plan.md"
target = os.path.realpath(os.path.join(project, target_rel))

# Path-safety: keep the target inside the project root (no traversal), mirroring
# serge plans.ts. On violation, fall back to <project>/plan.md.
if target != project and not target.startswith(project + os.sep):
    target = os.path.join(project, "plan.md")

stamp = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
MARKER = "Auto-saved by Serge plan-mode persistence"
header = (
    "<!-- " + MARKER + " on " + stamp + ".\n"
    "     Canonical plan for this feature; overwritten when you approve a new plan.\n"
    "     Full plan history: ~/.serge/plans/ -->\n\n"
)

# NEVER destroy a plan.md we did not write (added 2026-08-15).
# `plan.md` is a common filename — a repo can easily already have a hand-written
# one. This hook opened it "w" unconditionally, so the FIRST plan approved in
# such a repo silently replaced months of hand-written notes: no prompt, no
# backup, no message. Overwriting our OWN previous plan is the documented
# behaviour and stays; overwriting a file we did not write is data loss.
# Back up rather than refuse, because the contract of this hook is "never
# blocks" — a refusal would lose the new plan instead, which is the same bug
# pointed the other way.
#
# NOTE FOR EDITORS: this Python block is inside a single-quoted shell string,
# so an apostrophe anywhere here — including in a comment — closes that string
# and breaks the file. Keep this block apostrophe-free and run `bash -n` after.
backup_note = ""
try:
    if os.path.exists(target):
        with open(target, "r", encoding="utf-8", errors="ignore") as f:
            existing = f.read(4096)
        if MARKER not in existing:
            import shutil
            bstamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            bak = target + ".pre-serge-" + bstamp + ".bak"
            shutil.copy2(target, bak)
            backup_note = " (your existing " + os.path.basename(target) + \
                          " was NOT written by Serge — saved to " + \
                          os.path.basename(bak) + ")"
except Exception:
    # If we cannot read or back it up, do NOT overwrite — losing the new plan is
    # recoverable (it is still shelved in ~/.serge/plans/), losing theirs is not.
    sys.exit(0)

try:
    with open(target, "w", encoding="utf-8") as f:
        f.write(header + plan.rstrip() + "\n")
except Exception:
    sys.exit(0)  # fail-open: never disrupt the turn

# Give the SHELVED copy a name a human can find later. The engine files every
# plan under ~/.serge/plans/<random-slug>.md; plan.md above is only ever the
# latest one, so without this the previous plan is on a shelf with a name like
# "clever-soaring-reef" and is effectively gone. Renaming it here — at the one
# moment we know both the file and its title — is what makes `/plans` browsable.
# Best-effort and silent: a plan that cannot be renamed is still a saved plan.
shelved = None
for cand in (ti.get("planFilePath"), tr.get("filePath")):
    if isinstance(cand, str) and cand and os.path.exists(cand):
        shelved = cand
        break
if shelved:
    try:
        import subprocess
        renamer = os.path.expanduser(
            os.environ.get("SERGE_PLAN_RENAMER") or "~/.serge/plan-rename.sh")
        if os.path.exists(renamer):
            subprocess.run(["bash", renamer, shelved], timeout=10,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

out("Plan saved to " + os.path.relpath(target, project) +
    " — the executor can read it from source next session." + backup_note)
sys.exit(0)
'
exit 0
