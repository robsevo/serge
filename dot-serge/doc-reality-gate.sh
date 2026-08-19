#!/usr/bin/env bash
# Serge doc-reality gate — PostToolUse on mutating file tools, docs only.
# Local filesystem truth, $0, no LLM call, no network.
#
# WHY THIS EXISTS (user report, 2026-08-15): a README rewrite came back thin and
# had to be asked for twice. The deeper problem is structural, and it is the one
# thing docs have that code does not:
#
#   CODE THAT LIES FAILS. PROSE THAT LIES JUST SITS THERE.
#
# Every other mutating write in this workspace has something waiting for it —
# semgrep-scan.sh and algo-gate.sh on the PostToolUse event, path-reality-gate.sh
# before it, the test suite after it. Documentation had NOTHING. Worse, it was
# explicitly exempted: continue-on-unfinished.sh strips `.md|.txt|.rst|.adoc` out
# of `code_edits` (DOC_FILE, line ~124), so the feature-flow stop gate could not
# fire on a docs turn even in principle. A model could write "run `bun run docs`"
# into a README with no such script anywhere in package.json, declare the work
# done, and every gate in the house would agree.
#
# So this gate checks the two claims in a document that are decidable from the
# filesystem alone, on the text the edit JUST added:
#
#   A. SCRIPT COMMANDS — `npm|bun|pnpm|yarn run <name>` must name a script that
#      exists in package.json; `make <target>` must exist in the Makefile.
#   B. REPO PATHS — a repo-relative path is checked only when its first segment
#      is a real top-level entry of the workspace. That is the whole heuristic:
#      `src/tools/Foo.ts` gets checked because `src/` exists, `path/to/thing`
#      never does because `path/` does not. A miss is far cheaper than a false
#      fire, so anything ambiguous is simply not checked.
#
# It deliberately does NOT judge prose, structure, tone, or completeness — that
# is docs-directive.sh's job, injected before the writing starts. This gate only
# answers questions with a yes/no answer on disk.
#
# BLOCK ONCE, then get out of the way: each (session, file) blocks at most once.
# Re-issuing the same write goes through — a deliberately aspirational doc
# ("run `make release`, coming in v2") costs one extra turn, never a dead end.
# Same shape as path-reality-gate.sh and the feature-flow stop gate.
#
# Safety:
#   1. Off-switch: SERGE_DOC_GATE_DISABLE=1
#   2. Fail open on ANY error, timeout, or unreadable manifest. A package.json
#      that will not parse cannot prove a script is missing.
#   3. Only doc files INSIDE the workspace root (cwd) are gated.
#   4. Only the text this edit ADDED is examined. Walking into a legacy README
#      and being blamed for its existing rot is noise; you own what you touched.
#   5. Bounded: 1.5s deadline, first 20 findings, added text capped at 200 KB.
#
# Wired in ~/.serge/settings.json as PostToolUse "Edit|Write|MultiEdit".
set -uo pipefail

[ "${SERGE_DOC_GATE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

OUT="$(python3 - "$input" <<'PY'
import sys, json, os, re, time, hashlib

DEADLINE = time.time() + 1.5

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "PostToolUse":
    sys.exit(0)

tool = str(d.get("tool_name") or "")
if tool not in ("Write", "Edit", "MultiEdit"):
    sys.exit(0)

ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    sys.exit(0)

fp = str(ti.get("file_path") or "")
if not fp or not re.search(r"\.(?:md|markdown|rst|adoc|txt)$", fp, re.I):
    sys.exit(0)

root = str(d.get("cwd") or os.getcwd())
try:
    root = os.path.realpath(root)
    target = os.path.realpath(fp)
except Exception:
    sys.exit(0)
if not (target == root or target.startswith(root + os.sep)):
    sys.exit(0)   # docs outside the workspace: not ours to check

# Two document kinds are exempt because "this path does not exist yet" is their
# entire subject, so the gate has nothing true to say about them:
#   - claudedocs/ — the designated home for analyses, research and PROPOSALS.
#   - sample / example / template docs — measured on
#     docs/integrations/reference-samples.md, which shows where you WOULD put a
#     new gateway using a fictional one (`src/integrations/gateways/galaxy.ts`).
# Both are named by path, not guessed from content. A miss here is much cheaper
# than blocking a correct write.
rel = os.path.relpath(target, root)
rel_parts = rel.split(os.sep)
EXEMPT_DIR = {"claudedocs"}
EXEMPT_MARK = re.compile(r"(?:^|[-_./])(?:samples?|examples?|templates?)(?:$|[-_./])", re.I)
if EXEMPT_DIR.intersection(rel_parts) or EXEMPT_MARK.search(rel):
    sys.exit(0)

# --- the text this edit ADDED -----------------------------------------------
added = ""
if tool == "Write":
    added = str(ti.get("content") or "")
elif tool == "Edit":
    added = str(ti.get("new_string") or "")
else:
    edits = ti.get("edits")
    if isinstance(edits, list):
        added = "\n".join(
            str(e.get("new_string") or "") for e in edits if isinstance(e, dict)
        )
if not added.strip():
    sys.exit(0)
added = added[:200_000]

# --- block-once marker -------------------------------------------------------
sid = str(d.get("session_id") or "nosid")
mark = os.path.join(
    os.environ.get("TMPDIR", "/tmp"),
    "serge-docgate-%s-%s" % (
        hashlib.sha1(sid.encode("utf-8", "ignore")).hexdigest()[:12],
        hashlib.sha1(target.encode("utf-8", "ignore")).hexdigest()[:16],
    ),
)
already = os.path.exists(mark)

findings = []

# ============================================================================
# A. SCRIPT COMMANDS
# ============================================================================
# Only the EXPLICIT `run <name>` form. Bare `npm test` / `bun test` / `yarn add`
# are built-in subcommands, not scripts, and checking them against package.json
# would fire on every correct README in existence.
scripts = None
pkg_path = os.path.join(root, "package.json")
if os.path.exists(pkg_path):
    try:
        with open(pkg_path, encoding="utf-8") as fh:
            pkg = json.load(fh)
        s = pkg.get("scripts")
        if isinstance(s, dict):
            scripts = set(s.keys())
    except Exception:
        scripts = None   # unparseable manifest proves nothing: fail open

# `bun run scripts/build.ts` and `npm run ./x.mjs` execute a FILE, not a named
# script — measured false positive on docs/windows-aliases-and-launchers.md,
# which says "do not call source-only `bun run scripts/*.ts` entrypoints".
RUN_FILE = re.compile(r"[/\\]|\.(?:[cm]?[jt]s|sh|py|rb|go|lua)$", re.I)

if scripts is not None:
    for m in re.finditer(
        r"\b(npm|bun|pnpm|yarn)\s+run\s+([^\s`\'\"|&;()]+)", added
    ):
        if time.time() > DEADLINE:
            break
        name = m.group(2)
        if name.startswith("-") or RUN_FILE.search(name):
            continue
        if name not in scripts:
            findings.append((
                "%s run %s" % (m.group(1), name),
                "no such script in package.json",
            ))

mk = None
for cand in ("Makefile", "makefile", "GNUmakefile"):
    p = os.path.join(root, cand)
    if os.path.exists(p):
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                mk = fh.read(400_000)
        except Exception:
            mk = None
        break

if mk:
    targets = set(re.findall(r"^([A-Za-z0-9_][\w.-]*)\s*:(?!=)", mk, re.M))
    # .PHONY lists count as declarations too.
    for line in re.findall(r"^\.PHONY\s*:(.*)$", mk, re.M):
        targets.update(line.split())
    if targets:
        for m in re.finditer(r"\bmake\s+([A-Za-z0-9_][\w.-]*)", added):
            if time.time() > DEADLINE:
                break
            t = m.group(1)
            if t not in targets and not t.startswith("-"):
                findings.append(("make " + t, "no such target in the Makefile"))

# ============================================================================
# B. REPO PATHS
# ============================================================================
# Checked ONLY when the first segment is a real top-level entry of the
# workspace. That single rule is what keeps `path/to/your/file` and
# `your-project/src` from ever being looked at.
try:
    top = set(os.listdir(root))
except Exception:
    top = set()

PLACEHOLDER = re.compile(
    r"(?:^|/)(?:path|your|my|some|example|foo|bar|baz|name|project|repo|dir|"
    r"folder|file|xxx|todo|placeholder)(?:$|/)",
    re.IGNORECASE,
)
UNSAFE = re.compile(r"[<>{}*?$|\"'`\\]|\.\.\.")

# A token with at least one slash, made of path-safe characters.
PATHY = re.compile(r"(?<![\w./~-])\.{0,2}/?([\w.-]+(?:/[\w.-]+)+)/?(?![\w])")

seen_paths = set()
for m in PATHY.finditer(added):
    if time.time() > DEADLINE:
        break
    raw = m.group(1)
    whole = m.group(0)
    if raw in seen_paths:
        continue
    seen_paths.add(raw)

    if UNSAFE.search(whole) or PLACEHOLDER.search(raw):
        continue
    if "://" in whole or whole.lstrip().startswith("~"):
        continue
    # An absolute path is about the reader machine, not this repo.
    if whole.strip().startswith("/"):
        continue
    # Version strings, domains, and the like: a first segment that is not a real
    # top-level entry is never checked, which also covers every URL fragment.
    first = raw.split("/", 1)[0]
    if first not in top:
        continue
    if not os.path.exists(os.path.join(root, raw)):
        findings.append((raw, "no such file or directory in this repo"))

if not findings:
    sys.exit(0)

findings = findings[:20]

if already:
    head = ("doc-reality: still unresolved in %s (not blocking again) —"
            % os.path.relpath(target, root))
else:
    try:
        with open(mark, "w"):
            pass
    except Exception:
        pass
    head = (
        "Doc-reality gate: %s now documents %d thing%s that do not exist. "
        "A wrong command in a doc never fails — it just sits there looking "
        "correct — so it gets checked here instead."
        % (
            os.path.relpath(target, root),
            len(findings),
            "" if len(findings) == 1 else "s",
        )
    )

lines = [head]
for what, why in findings:
    lines.append("  %-44s %s" % (what, why))
lines.append(
    "Fix each one against what is really in the repo: read package.json / the "
    "Makefile for the real names, and check the real paths, then correct the "
    "document. If one is deliberately aspirational (\"coming in v2\") or "
    "historical (a post-mortem naming a file that was correctly deleted), say so "
    "in ONE line and re-issue the write — this file will not be blocked twice."
)

print(json.dumps({"block": not already, "text": "\n".join(lines)}))
PY
)" || exit 0

[ -n "$OUT" ] || exit 0

DECISION="$(printf '%s' "$OUT" | python3 -c 'import sys,json; print("1" if json.load(sys.stdin).get("block") else "0")' 2>/dev/null)" || exit 0
TEXT="$(printf '%s' "$OUT" | python3 -c 'import sys,json; sys.stdout.write(json.load(sys.stdin).get("text",""))' 2>/dev/null)" || exit 0
[ -n "$TEXT" ] || exit 0

if [ "$DECISION" = "1" ]; then
  printf '%s\n' "$TEXT" >&2
  exit 2
fi

printf '%s' "$TEXT" | python3 -c '
import sys, json
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": sys.stdin.read(),
}}))'
exit 0
