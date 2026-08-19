#!/usr/bin/env bash
# Serge path-reality gate — PreToolUse on mutating file tools ($0, no LLM).
#
# WHY THIS EXISTS (measured on an OS-image repo, 2026-07-29):
# the model had already Read `archiso_profile/airootfs/opt/serge/linkage-cleanup.sh`
# and Glob'd the whole tree, then wrote to
#   $HOME/programs/osimage/airootfs/root/.env.skel        <-- invented
# when the real tree is
#   $HOME/programs/osimage/archiso_profile/airootfs/root/ <-- real
# FileWriteTool.ts:254 mkdirs the parent, so the invented path SUCCEEDED. No
# error, no signal, a phantom directory tree on disk, and four user corrections
# later nobody had noticed. The next Edit against the same invented path failed,
# and the model went hunting with three redundant greps instead of trusting the
# path it had already read.
#
# Prose can't fix this: CONSTITUTION.md:141 already says "never
# reference a file path it has not seen in a tool result". The workhorse seat
# reads that and still guesses. So this gate turns the guess into a hard,
# deterministic filesystem fact BEFORE the write lands.
#
# Three checks, all pure filesystem truth, no heuristics about intent:
#   A. Edit/MultiEdit/NotebookEdit on a file that DOES NOT EXIST, while a file
#      of the same basename exists elsewhere in the workspace → deny, name the
#      real path(s). (The tool would fail anyway; this replaces a useless
#      "File does not exist" with the answer.)
#   B. Any mutating write whose PARENT DIRECTORY does not exist, while a real
#      directory in the workspace shares the tail of the path → deny, name the
#      real directories. This is the phantom-tree case above.
#   C. Write of a NEW env-family file (.env*, *.env, env.skel...) when the
#      workspace already ships env templates → deny, name them, so the model
#      follows the existing format instead of inventing a variable list.
#
# BLOCK ONCE, then get out of the way: each (session, target) is denied at most
# once. Re-issuing the same call goes through — so a deliberate new directory
# tree costs one extra turn, never a dead end. That is the same
# block-once-with-evidence shape as the feature-flow stop gate.
#
# Safety:
#   1. Off-switch: SERGE_PATH_GATE_DISABLE=1
#   2. Fail open on ANY error, timeout, or incomplete index — an index that
#      didn't finish cannot prove a path is invented.
#   3. Only paths INSIDE the workspace root (cwd) are gated. /etc, ~/.config,
#      other projects: untouched.
#   4. Bounded walk: 2s deadline, 40k dirs, skips node_modules/.git/dist/etc.
#
# Wired in ~/.serge/settings.json as PreToolUse "Write|Edit|MultiEdit|NotebookEdit".
set -uo pipefail

[ "${SERGE_PATH_GATE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re, time, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "PreToolUse":
    sys.exit(0)

tool = str(d.get("tool_name") or "")
if tool not in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
    sys.exit(0)

ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    sys.exit(0)
raw = ti.get("file_path") or ti.get("notebook_path") or ""
if not isinstance(raw, str) or not raw.strip():
    sys.exit(0)

target = os.path.abspath(os.path.expanduser(raw.strip()))
root = os.path.abspath(os.path.expanduser(str(d.get("cwd") or ".")))

# Outside the workspace → not our business.
if not (target == root or target.startswith(root + os.sep)):
    sys.exit(0)
# Never gate a path that already resolves.
if os.path.lexists(target) and tool != "Write":
    sys.exit(0)

parent = os.path.dirname(target)
base = os.path.basename(target)

# --- block-once marker ------------------------------------------------------
sid = str(d.get("session_id") or "nosid")
mark = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-pathgate-%s-%s"
    % (
        hashlib.sha1(sid.encode("utf-8", "ignore")).hexdigest()[:12],
        hashlib.sha1(target.encode("utf-8", "ignore")).hexdigest()[:16],
    ),
)
if os.path.exists(mark):
    sys.exit(0)  # already warned about this exact target: insistence wins


def deny(reason):
    try:
        with open(mark, "w"):
            pass
    except Exception:
        pass
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    sys.exit(0)


RETRY = (
    "If you genuinely mean this new path, re-issue this exact call and it will "
    "go through — this gate blocks a given target once."
)

# Nothing to check: parent exists, and for Write we only care about the
# env-family duplicate case below.
need_index = (not os.path.isdir(parent)) or tool == "Write" or not os.path.lexists(target)
if not need_index:
    sys.exit(0)

# --- bounded workspace index ------------------------------------------------
SKIP = {
    ".git", "node_modules", "dist", "build", "out", ".venv", "venv", "env",
    "__pycache__", ".next", ".nuxt", ".cache", "target", "vendor", ".turbo",
    ".mypy_cache", ".pytest_cache", ".tox", ".ruff_cache", "coverage",
    "site-packages", ".terraform", ".gradle", ".idea", ".svelte-kit",
}
DEADLINE = time.time() + 2.0
MAX_DIRS = 40000

dirs = []
by_base = {}
truncated = False
seen = 0
try:
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = [
            x for x in dirnames if x not in SKIP and not x.endswith(".egg-info")
        ]
        dirs.append(dirpath)
        for fn in filenames:
            by_base.setdefault(fn, []).append(os.path.join(dirpath, fn))
        seen += 1
        if seen > MAX_DIRS or time.time() > DEADLINE:
            truncated = True
            break
except Exception:
    truncated = True

if truncated:
    sys.exit(0)  # incomplete index cannot prove anything is invented


def show(paths, limit=6):
    out = []
    for p in paths[:limit]:
        try:
            sz = os.path.getsize(p)
            out.append("  - %s (%s)" % (p, "%.1f KB" % (sz / 1024.0) if sz >= 1024 else "%d B" % sz))
        except Exception:
            out.append("  - %s" % p)
    if len(paths) > limit:
        out.append("  ... and %d more" % (len(paths) - limit))
    return "\n".join(out)


# --- Check A: editing a file that does not exist, but the name does ---------
if tool in ("Edit", "MultiEdit", "NotebookEdit") and not os.path.lexists(target):
    hits = [p for p in by_base.get(base, []) if p != target]
    if hits:
        deny(
            "That file does not exist: %s\n\n"
            "A file named %s DOES exist in this workspace, at:\n%s\n\n"
            "You are editing a path you assembled, not one you read. Use the real "
            "path above (Read it first if its current contents aren't already in "
            "this session). %s" % (target, base, show(hits), RETRY)
        )

# --- Check B: parent directory does not exist, but its tail does ------------
if not os.path.isdir(parent):
    try:
        rel = os.path.relpath(parent, root)
    except Exception:
        rel = ""
    parts = [p for p in rel.split(os.sep) if p and p != "."]
    cands = []
    if parts:
        for k in range(min(4, len(parts)), 1, -1):
            tail = os.sep.join(parts[-k:])
            cands = [x for x in dirs if x.endswith(os.sep + tail)]
            if cands:
                break
    if cands:
        deny(
            "The directory you are writing into does not exist: %s/\n\n"
            "But these REAL directories match the tail of that path:\n%s\n\n"
            "Write silently creates missing parent directories, so an invented "
            "path here would look like success and leave a phantom tree on disk "
            "that nobody notices. Check which of the above you actually mean "
            "(Glob or ls it), then write there. %s" % (parent, show(cands), RETRY)
        )

# --- Check C: new env file when the workspace already has env templates ----
ENV_RE = re.compile(
    r"^(\.env([._-].*)?|env([._-].*)?\.(example|sample|skel|template|tmpl|dist)|"
    r".*\.env|env\.(skel|example|sample|template))$",
    re.IGNORECASE,
)
TEMPLATE_RE = re.compile(
    r"^(\.env\.(example|sample|skel|template|tmpl|dist|local)|"
    r"env\.(example|sample|skel|template|tmpl|dist)|"
    r".*\.env\.(example|sample|template)|\.env)$",
    re.IGNORECASE,
)

if tool == "Write" and not os.path.lexists(target) and ENV_RE.match(base):
    existing = []
    for fn, paths in by_base.items():
        if TEMPLATE_RE.match(fn):
            existing.extend(paths)
    existing = sorted(set(existing) - {target})
    if existing:
        annotated = []
        for p in existing[:6]:
            keys = ""
            try:
                # Commented KEY= lines count: an .env.example is usually all
                # documentation (serge's own has 124 commented keys, 1 live).
                with open(p, "r", errors="ignore") as fh:
                    n = sum(
                        1
                        for ln in fh
                        if re.match(r"^\s*#?\s*[A-Za-z_][A-Za-z0-9_]*\s*=", ln)
                    )
                if n:
                    keys = ", %d keys" % n
            except Exception:
                pass
            try:
                sz = os.path.getsize(p)
                annotated.append(
                    "  - %s (%s%s)"
                    % (p, "%.1f KB" % (sz / 1024.0) if sz >= 1024 else "%d B" % sz, keys)
                )
            except Exception:
                annotated.append("  - %s%s" % (p, keys))
        if len(existing) > 6:
            annotated.append("  ... and %d more" % (len(existing) - 6))
        deny(
            "You are about to author a new env file (%s) from scratch, but this "
            "workspace already ships env templates:\n%s\n\n"
            "Read the closest one and follow ITS variable names and format — an "
            "invented key list is wrong in a way that is invisible until "
            "something silently reads an empty value. %s" % (base, "\n".join(annotated), RETRY)
        )

sys.exit(0)
PY
exit 0
