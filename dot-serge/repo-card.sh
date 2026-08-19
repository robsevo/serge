#!/usr/bin/env bash
# Serge repo card — SessionStart hook ($0, no LLM, no network).
#
# WHY: the measured failure (2026-07-29) was not that Serge
# refused to read — it read 25 files serially — but that it had no cheap picture
# of the repo's SHAPE, so it invented `osimage/airootfs/root/` instead of the real
# `osimage/archiso_profile/airootfs/root/`, and invented an env key list while
# `.env.example` sat one directory away. Both are structure facts, and structure
# facts are exactly what a hook can establish for free.
#
# So: one compact card of verified facts at session start — what this project is,
# its top-level directories, its entry points, its real test/lint commands, its
# config templates, its git head. No advice, no instructions to "look first":
# just the ground truth the model would otherwise guess at.
#
# Complements the two grounding hooks: reference-resolve.sh answers "what is this
# path the user named", path-reality-gate.sh blocks a write to a path that isn't
# there, and this answers "what does this repo look like" before either is needed.
#
# Budget: capped at ~1100 chars (~280 tokens) per session, cached for an hour and
# invalidated when a manifest changes, so repeated sessions in one repo re-use it.
#
# WIRED TO THREE EVENTS (2026-07-30), one card generator each:
#   SessionStart     — the first card, as before.
#   SubagentStart    — subagents start COLD. `agents/scout.md` even sets
#                      omitClaudeMd: true, so the agent that exists to find
#                      things in unfamiliar code was the least grounded process
#                      in the system — and discovery-delegate.sh now routes work
#                      to it. Verified: SubagentStart is one of the seven events
#                      that accept additionalContext (hooks.ts:830).
#   UserPromptSubmit — cwd-drift only. A card emitted at session start silently
#                      describes the WRONG repo the moment the session moves
#                      project (this one went serge -> osimage -> fixtures). Emits a
#                      fresh card ONLY when the project root changed since the
#                      last one; otherwise prints nothing, so ordinary turns cost
#                      zero tokens. CwdChanged would be the natural event but it
#                      canNOT inject context in this fork — it only receives a
#                      CLAUDE_ENV_FILE (hooks.ts:1104-1115).
#
# Safety:
#   1. Off-switch: SERGE_REPO_CARD_DISABLE=1
#   2. Never runs a build/test command — it only REPORTS the ones declared in
#      manifests. Reads no file contents into the card beyond names and counts.
#   3. Bounded walk (1.5s, 20k dirs); silent no-op outside a project dir.
#   4. git is read via `git -C` with a timeout; a non-repo is stated as such.
#
# Wired in ~/.serge/settings.json as SessionStart "startup|resume|clear|compact".
set -uo pipefail

[ "${SERGE_REPO_CARD_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the model, not the harness: handing a golden task a free map of
# the repo would flatter the result and make it incomparable to the baseline.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

python3 - "$input" <<'PY'
import sys, json, os, re, time, hashlib, subprocess, glob

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    d = {}

root = os.path.abspath(os.path.expanduser(str(d.get("cwd") or os.getcwd())))
HOME = os.path.expanduser("~")

# Not a project: home, /, or a bare temp dir.
if root in (HOME, "/") or not os.path.isdir(root):
    sys.exit(0)

CACHE_DIR = os.path.join(HOME, ".serge", "cache")
cache = os.path.join(
    CACHE_DIR, "repo-card-%s.txt" % hashlib.sha1(root.encode()).hexdigest()[:16]
)
MANIFESTS = [
    "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "Makefile",
    "requirements.txt", "build.gradle", "CMakeLists.txt", "composer.json",
]


# Which event are we serving? The card is identical; only WHEN it is emitted
# differs. Only these events accept hookSpecificOutput.additionalContext in this
# fork (hooks.ts:805-845) — CwdChanged notably does NOT, it only gets a
# CLAUDE_ENV_FILE for env vars, so cwd drift is handled on UserPromptSubmit below.
EVENT = str(d.get("hook_event_name") or "SessionStart")
if EVENT not in ("SessionStart", "SubagentStart", "UserPromptSubmit", "Setup"):
    sys.exit(0)

# Per-session (per-subagent) record of the root we last emitted a card for.
# SessionStart/SubagentStart always emit. UserPromptSubmit emits ONLY when the
# project root changed mid-session — otherwise it would re-send the same card
# every turn.
_who = str(d.get("agent_id") or d.get("session_id") or "nosid")
seen_p = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-repocard-%s" % hashlib.sha1(_who.encode()).hexdigest()[:16],
)
prev_root = ""
try:
    with open(seen_p, encoding="utf-8") as fh:
        prev_root = fh.read().strip()
except Exception:
    pass

MOVED = EVENT == "UserPromptSubmit" and prev_root and prev_root != root
if EVENT == "UserPromptSubmit" and not MOVED:
    sys.exit(0)  # same project as the card already in context: say nothing


def emit(ctx):
    try:
        with open(seen_p, "w", encoding="utf-8") as fh:
            fh.write(root)
    except Exception:
        pass
    if MOVED:
        ctx = ("The working directory changed project since the last card "
               "(was %s). The card below describes where you are NOW; anything "
               "you remember about paths in the old project does not apply "
               "here.\n\n" % prev_root) + ctx
    elif EVENT == "SubagentStart":
        ctx = ("You are a subagent and start with no project context of your "
               "own. These are verified facts about the repository you are "
               "working in — use these exact paths and never invent variants; "
               "if you need something not listed, search for it before naming "
               "it.\n\n") + ctx
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": EVENT,
        "additionalContext": ctx,
    }}))
    sys.exit(0)


# --- cache: 1h TTL, invalidated by any manifest newer than the cache ---------
try:
    if os.path.isfile(cache):
        age = time.time() - os.path.getmtime(cache)
        cm = os.path.getmtime(cache)
        stale = any(
            os.path.isfile(os.path.join(root, m))
            and os.path.getmtime(os.path.join(root, m)) > cm
            for m in MANIFESTS
        )
        if age < 3600 and not stale:
            with open(cache, encoding="utf-8") as fh:
                body = fh.read().strip()
            if body:
                emit(body)
except Exception:
    pass

SKIP = {
    ".git", "node_modules", "dist", "build", "out", ".venv", "venv",
    "__pycache__", ".next", ".nuxt", ".cache", "target", "vendor", ".turbo",
    ".mypy_cache", ".pytest_cache", ".tox", ".ruff_cache", "coverage",
    "site-packages", ".terraform", ".gradle", ".idea", ".svelte-kit",
}


def sh(args, timeout=3):
    try:
        r = subprocess.run(
            args, cwd=root, capture_output=True, text=True, timeout=timeout
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


lines = []

# --- identity ---------------------------------------------------------------
name = os.path.basename(root)
ident = ""
pkg = {}
pj = os.path.join(root, "package.json")
if os.path.isfile(pj):
    try:
        with open(pj, encoding="utf-8", errors="ignore") as fh:
            pkg = json.load(fh)
        ident = str(pkg.get("description") or "")[:120]
        if pkg.get("name"):
            name = "%s (%s)" % (name, pkg["name"])
        if pkg.get("version"):
            name += " v%s" % pkg["version"]
    except Exception:
        pkg = {}
if not ident:
    for rd in ("README.md", "README", "readme.md", "README.txt"):
        rp = os.path.join(root, rd)
        if os.path.isfile(rp):
            try:
                with open(rp, encoding="utf-8", errors="ignore") as fh:
                    for ln in fh:
                        s = ln.strip().lstrip("#").strip()
                        if len(s) > 8 and not s.startswith(("!", "[", "<", "-", "=")):
                            ident = s[:120]
                            break
            except Exception:
                pass
            break
lines.append("%s — %s" % (name, ident) if ident else name)
lines.append("root: %s" % root)

# --- top-level layout with file counts (the anti-phantom-path fact) ---------
counts = {}
total = 0
deadline = time.time() + 1.5
try:
    for entry in sorted(os.listdir(root)):
        if entry in SKIP or entry.startswith("."):
            continue
        p = os.path.join(root, entry)
        if not os.path.isdir(p):
            continue
        n = 0
        for dirpath, dirnames, filenames in os.walk(p, followlinks=False):
            dirnames[:] = [x for x in dirnames if x not in SKIP]
            n += len(filenames)
            if time.time() > deadline:
                break
        counts[entry] = n
        total += n
        if time.time() > deadline:
            break
except Exception:
    pass
if counts:
    top = sorted(counts.items(), key=lambda kv: -kv[1])[:10]
    lines.append(
        "top-level dirs: "
        + ", ".join("%s/ (%d)" % (k, v) for k, v in top)
        + ("" if len(counts) <= 10 else " +%d more" % (len(counts) - 10))
    )

# --- stack + declared commands (never executed, only reported) --------------
present = [m for m in MANIFESTS if os.path.isfile(os.path.join(root, m))]
if present:
    lines.append("manifests: " + ", ".join(present))
scripts = pkg.get("scripts") or {}
cmds = []
for key in ("test", "lint", "typecheck", "build", "dev"):
    if isinstance(scripts, dict) and key in scripts:
        runner = "bun run" if os.path.isfile(os.path.join(root, "bun.lock")) else "npm run"
        cmds.append("%s=%s %s" % (key, runner, key))
if cmds:
    lines.append("declared scripts: " + ", ".join(cmds))

# --- entry points -----------------------------------------------------------
entries = []
b = pkg.get("bin")
if isinstance(b, str):
    entries.append(b)
elif isinstance(b, dict):
    entries.extend(list(b.values())[:3])
if pkg.get("main"):
    entries.append(str(pkg["main"]))
for cand in ("src/entrypoints", "src/main.py", "main.py", "src/main.rs", "cmd"):
    if os.path.exists(os.path.join(root, cand)):
        entries.append(cand)
if not entries:
    # No manifest at all (shell / OS-image / script projects — the OS-image repo where
    # this failure happened is exactly this shape). Top-level executables ARE the
    # entry points there, and naming them beats saying nothing.
    try:
        for entry in sorted(os.listdir(root)):
            p = os.path.join(root, entry)
            if os.path.isfile(p) and os.access(p, os.X_OK) and not entry.startswith("."):
                entries.append(entry)
    except Exception:
        pass
entries = [e for e in dict.fromkeys(entries) if e][:4]
if entries:
    lines.append("entry points: " + ", ".join(entries))

# --- config templates (the .env.example the model invented instead) ---------
tmpl = []
for pat in (".env*", "*.example", "*.sample", "*.template"):
    try:
        tmpl.extend(glob.glob(os.path.join(root, pat)))
    except Exception:
        pass
tmpl = sorted({t for t in tmpl if os.path.isfile(t)})
if tmpl:
    parts = []
    for t in tmpl[:3]:
        kc = 0
        try:
            with open(t, encoding="utf-8", errors="ignore") as fh:
                kc = sum(
                    1 for ln in fh
                    if re.match(r"^\s*#?\s*[A-Za-z_][A-Za-z0-9_]*\s*=", ln)
                )
        except Exception:
            pass
        parts.append(
            "%s%s" % (os.path.basename(t), (" (%d keys)" % kc) if kc else "")
        )
    lines.append("config templates: " + ", ".join(parts))

# --- git --------------------------------------------------------------------
if os.path.isdir(os.path.join(root, ".git")):
    br = sh(["git", "branch", "--show-current"]) or "(detached)"
    head = sh(["git", "log", "-1", "--format=%h %s"])[:80]
    dirty = sh(["git", "status", "--porcelain"])
    nd = len([x for x in dirty.splitlines() if x.strip()]) if dirty else 0
    lines.append(
        "git: branch %s, head %s%s"
        % (br, head, (", %d uncommitted file(s)" % nd) if nd else ", clean")
    )
else:
    lines.append("git: NOT a git repository (no commit history, no rollback)")

body = (
    "Repo card — facts read from disk just now by a local hook, not recalled. "
    "Trust these over any memory of this project; anything not listed here is "
    "unverified.\n"
    + "\n".join("  " + l for l in lines)
)
if len(body) > 1100:
    body = body[:1090].rstrip() + " …"

try:
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(cache, "w", encoding="utf-8") as fh:
        fh.write(body)
except Exception:
    pass

emit(body)
PY
exit 0
