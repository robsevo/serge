#!/usr/bin/env bash
# Serge compact-survival — PreCompact capture + SessionStart(compact) re-inject.
# $0, no LLM, no network.
#
# WHY: compaction is where a long session loses the things it worked hardest to
# establish — the absolute paths it actually read, the command that actually
# verified the change, the task that was still open. Afterwards the model is
# fluent about a codebase it can no longer cite, which is precisely the state
# that produces invented paths (see path-reality-gate.sh for the damage).
#
# TWO HALVES, one script:
#
#  1. PreCompact — reads `transcript_path` (the last moment the full history
#     exists) and writes a deterministic snapshot to
#     ~/.serge/cache/compact-survival-<sid>.md: file paths that appeared in real
#     tool calls AND still exist on disk, plus verify/test/build commands that
#     actually exited 0. No summarising, no model call — just the facts, pulled
#     from tool results rather than from prose.
#
#     Its STDOUT is not a data channel: this fork feeds PreCompact stdout in as
#     the compaction's own custom instructions (hooks.ts:4300-4305) and ALSO
#     echoes it to the user as "PreCompact [...] completed successfully: <text>".
#     So stdout gets one short instruction; the payload goes to the file.
#     (PreCompact is NOT one of the seven events that accept
#     hookSpecificOutput.additionalContext — hooks.ts:805-845 — so injecting
#     from here is impossible; that is what half 2 is for.)
#
#  2. SessionStart, matcher `compact` — fires right after compaction, IS allowed
#     to inject additionalContext, and hands the snapshot back. The file is
#     consumed (deleted) on inject so a stale snapshot can never resurface in an
#     unrelated session.
#
# Safety: off-switch SERGE_COMPACT_SURVIVAL_DISABLE=1 · fails open silently ·
# read-only on the transcript · snapshot capped ~2600 chars · never emits file
# CONTENTS, only paths, commands and counts.
set -uo pipefail

[ "${SERGE_COMPACT_SURVIVAL_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the model, not the harness. This one alters TWO things: the
# post-compaction context AND the compaction's own custom instructions (its
# PreCompact stdout), so an eval run that compacts would diverge twice over.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

python3 - "$input" <<'PY'
import sys, json, os, re, hashlib, time

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

event = str(d.get("hook_event_name") or "")
sid = str(d.get("session_id") or "nosid")
HOME = os.path.expanduser("~")
CACHE = os.path.join(HOME, ".serge", "cache")
snap = os.path.join(CACHE, "compact-survival-%s.md"
                    % hashlib.sha1(sid.encode()).hexdigest()[:16])

VERIFY_RE = re.compile(
    r"\b(pytest|jest|vitest|bun test|npm (?:run )?test|yarn test|pnpm test|go test|"
    r"cargo test|make test|tox|mvn test|gradle test|rspec|phpunit|"
    r"tsc|typecheck|mypy|ruff|eslint|shellcheck|bash -n|"
    r"npm run build|bun run build|cargo build|make build|"
    r"\./tests?/[\w./-]+\.sh|test[-_][\w-]+\.sh)\b", re.I)


# ------------------------------------------------- 2. re-inject after compact ---
if event == "SessionStart":
    body = ""
    try:
        with open(snap, encoding="utf-8") as fh:
            body = fh.read().strip()
    except Exception:
        # Same session should hit the keyed file; tolerate a sid change by taking
        # a very recent snapshot instead of silently losing the capture.
        try:
            cands = [
                os.path.join(CACHE, f) for f in os.listdir(CACHE)
                if f.startswith("compact-survival-")
            ]
            cands = [c for c in cands if time.time() - os.path.getmtime(c) < 600]
            if cands:
                snap = max(cands, key=os.path.getmtime)
                with open(snap, encoding="utf-8") as fh:
                    body = fh.read().strip()
        except Exception:
            pass
    if not body:
        sys.exit(0)
    try:
        os.unlink(snap)   # consume: never resurface in an unrelated session
    except Exception:
        pass
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext":
            "Context was just compacted. These are facts recovered from the "
            "pre-compaction history — they are verified, not recalled. Paths "
            "below existed on disk at capture time; commands below actually ran "
            "and exited 0. Prefer them over anything you think you remember, and "
            "if you need a path that is not listed, search for it rather than "
            "reconstructing it.\n\n" + body,
    }}))
    sys.exit(0)

# --------------------------------------------- 3. archive what compaction kept ---
# PostCompact can neither block nor inject (hooks.ts:805-845), so it is purely a
# recorder — but it is the ONLY place `compact_summary` is exposed. Keeping it
# makes "serge forgot X" answerable after the fact: you can read exactly what
# survived instead of guessing. Side effect only; prints nothing.
if event == "PostCompact":
    summary = str(d.get("compact_summary") or "").strip()
    if not summary:
        sys.exit(0)
    log = os.path.join(CACHE, "compact-log")
    try:
        os.makedirs(log, exist_ok=True)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        with open(os.path.join(log, "%s-%s.md" % (stamp, sid[:8])), "w",
                  encoding="utf-8") as fh:
            fh.write("# compaction %s (trigger: %s)\n\n%s\n"
                     % (stamp, d.get("trigger"), summary[:20000]))
        # Keep the last 20 only — this is a debugging aid, not an archive.
        keep = sorted(f for f in os.listdir(log) if f.endswith(".md"))
        for old in keep[:-20]:
            try:
                os.unlink(os.path.join(log, old))
            except Exception:
                pass
    except Exception:
        pass
    sys.exit(0)

if event != "PreCompact":
    sys.exit(0)

# ---------------------------------------------------- 1. capture before compact ---
tx = str(d.get("transcript_path") or "")
if not tx or not os.path.exists(tx):
    sys.exit(0)

FILE_TOOLS = {"Read", "Edit", "Write", "MultiEdit", "NotebookEdit"}
paths, cmds = [], []
ok_ids = set()
fail_ids = set()
pending = {}   # tool_use_id -> command string (Bash), resolved by its result

try:
    size = os.path.getsize(tx)
    with open(tx, "rb") as fh:
        if size > 12_000_000:          # only the tail of a huge transcript
            fh.seek(size - 12_000_000)
            fh.readline()
        lines = fh.read().decode("utf-8", "ignore").splitlines()
except Exception:
    sys.exit(0)

for ln in lines:
    if not ln.strip():
        continue
    try:
        e = json.loads(ln)
    except Exception:
        continue
    msg = e.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        continue
    for b in content:
        if not isinstance(b, dict):
            continue
        t = b.get("type")
        if t == "tool_use":
            inp = b.get("input") or {}
            if not isinstance(inp, dict):
                continue
            if b.get("name") in FILE_TOOLS:
                p = inp.get("file_path") or inp.get("notebook_path")
                if isinstance(p, str) and p.strip():
                    paths.append(p.strip())
            elif b.get("name") == "Bash":
                c = inp.get("command")
                if isinstance(c, str) and VERIFY_RE.search(c):
                    pending[str(b.get("id"))] = c.strip()
        elif t == "tool_result":
            tid = str(b.get("tool_use_id"))
            (fail_ids if b.get("is_error") else ok_ids).add(tid)

# A command counts only if its own result was not an error.
for tid, c in pending.items():
    if tid in ok_ids and tid not in fail_ids:
        cmds.append(c)

# Most recent first, deduped, and only paths that really exist now.
def uniq_recent(seq, limit):
    out, seen = [], set()
    for x in reversed(seq):
        if x in seen:
            continue
        seen.add(x)
        out.append(x)
        if len(out) >= limit:
            break
    return out

paths = [p for p in uniq_recent(paths, 40) if os.path.exists(p)][:14]
cmds = uniq_recent(cmds, 6)

if not paths and not cmds:
    sys.exit(0)

out = []
if paths:
    out.append("Files this session actually opened or changed (verified present):")
    out += ["  " + p for p in paths]
if cmds:
    out.append("\nCommands that ran and exited 0 — reuse these to verify, don't invent new ones:")
    out += ["  " + c[:160] for c in cmds]

body = "\n".join(out)
if len(body) > 2600:
    body = body[:2560].rstrip() + "\n  … (truncated)"

try:
    os.makedirs(CACHE, exist_ok=True)
    with open(snap, "w", encoding="utf-8") as fh:
        fh.write(body)
except Exception:
    sys.exit(0)   # nothing to re-inject later, so say nothing now

# stdout == compaction custom instructions + a line shown to the user. Keep short.
print("Preserve exact file paths, the commands already used to verify, and any "
      "unfinished task; a verified snapshot of both was saved and will be "
      "restored automatically after compaction.")
PY
exit 0
