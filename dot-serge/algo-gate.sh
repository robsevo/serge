#!/usr/bin/env bash
# PostToolUse hook — price the algorithm and check the boundaries on the code that
# was JUST written. Local CPU, zero token cost on a clean edit.
#
# WHY THIS IS A HOOK AND NOT A SKILL. Two measured properties of model-written code
# motivate it, and neither is fixed by advice the model reads once:
#
#   1. It carries more defects than human code, concentrated in slips that READ
#      correctly — `>` for `>=`, `<= arr.length`, an index off by one, a loop that
#      never advances, a catch that eats the error. A model reviewing its own diff
#      re-reads the same intent it just wrote and confirms it. A checker does not.
#
#   2. It is bulkier for the same behavior, and bulk is not free — it is extra
#      passes, extra copies, re-derived work inside loops, and N round trips where
#      one would do. "Looks fine" is not a complexity budget.
#
# So the check fires MECHANICALLY on every source edit, at the moment the code
# exists, and blocks (exit 2) so the finding is fixed before the turn continues —
# the same shape as semgrep-scan.sh, which sits on this same event.
#
# ONLY THE LINES THIS EDIT TOUCHED are reported. Walking into a legacy file and
# being told about its existing O(n²) is noise the model cannot act on; being told
# about the O(n²) it wrote thirty seconds ago is a fix. You own what you touched.
#
# Blocking vs advisory:
#   bounds + bigo  → BLOCK (exit 2). A wrong boundary is a bug; an N+1 in a request
#                    path is a production incident. Both are cheapest to fix now.
#   fluff          → never blocks. It rides along in a blocking message for free,
#                    and on its own only surfaces as non-blocking context once the
#                    removable volume crosses SERGE_ALGO_FLUFF_LINES (default 4) —
#                    a gate that stops a turn over one stray console.log would cost
#                    more than the line it removes.
#
# Toggles:
#   SERGE_ALGO_GATE_DISABLE=1   off entirely
#   SERGE_ALGO_MIN_SEV=high     blocking threshold (certain|high|medium|low)
#   SERGE_ALGO_FLUFF_LINES=4    removable-line count that earns an advisory note
#   SERGE_ALGO_MAX_FINDINGS=6   cap on findings per message (keeps feedback actionable)
set -uo pipefail

[ "${SERGE_ALGO_GATE_DISABLE:-0}" = "1" ] && exit 0
# Evals measure the MODEL, not the scaffolding — same guard as semgrep-scan.sh and
# reasoning-overlay.sh, so eval deltas stay attributable to the seat.
[ "${SERGE_EVAL:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

SH="${SERGE_HOME:-$HOME/.serge}"
CHECKER="${SERGE_ALGO_CHECKER:-$SH/skills/complexity/algo_check.py}"
[ -f "$CHECKER" ] || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

# The payload goes in as argv, not on stdin: `python3 -` already consumes stdin to
# read the program from the heredoc, so a piped payload would arrive at EOF and the
# hook would silently no-op. Same shape as path-reality-gate.sh / subagent-brief-gate.sh.
# stderr is swallowed: a hook that prints a traceback feeds it to the model as if it
# were a finding. Any internal error must read as "clean", never as noise.
OUT="$(SERGE_ALGO_CHECKER="$CHECKER" python3 - "$input" 2>/dev/null <<'PY'
import json, os, re, subprocess, sys, hashlib, tempfile

SRC_EXT = {".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
MIN_SEV = os.environ.get("SERGE_ALGO_MIN_SEV", "high")
FLUFF_MIN = int(os.environ.get("SERGE_ALGO_FLUFF_LINES", "4") or 4)
MAX_FIND = int(os.environ.get("SERGE_ALGO_MAX_FINDINGS", "6") or 6)
CHECKER = os.environ["SERGE_ALGO_CHECKER"]

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

ti = d.get("tool_input") or {}
path = ti.get("file_path") or ti.get("path") or ""
if not path or os.path.splitext(path)[1].lower() not in SRC_EXT:
    sys.exit(0)
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        src = fh.read()
except OSError:
    sys.exit(0)

# ---- which lines did THIS edit produce? -------------------------------------
# Edit/MultiEdit carry the replacement text; locating it in the file on disk gives
# the touched span exactly. Write authored the whole file, so all of it is new.
new_texts = []
if "content" in ti and isinstance(ti["content"], str):
    new_texts = None                                  # Write ⇒ whole file
else:
    if isinstance(ti.get("new_string"), str):
        new_texts.append(ti["new_string"])
    for e in (ti.get("edits") or []):
        if isinstance(e, dict) and isinstance(e.get("new_string"), str):
            new_texts.append(e["new_string"])

if new_texts is None:
    ranges = "1-%d" % (src.count("\n") + 1)
elif not new_texts:
    sys.exit(0)
else:
    spans = []
    for t in new_texts:
        if not t.strip():
            continue
        i = src.find(t)
        if i < 0:                                     # reformatted on write; fall back
            first = t.strip().splitlines()[0].strip()
            i = src.find(first) if first else -1
            if i < 0:
                continue
            t = first
        start = src.count("\n", 0, i) + 1
        spans.append((start, start + t.count("\n")))
    if not spans:
        sys.exit(0)
    ranges = ",".join("%d-%d" % s for s in spans)

# Siblings in the same directory come along as CONTEXT so a call out of the edited
# file resolves — `for (const o of orders) enrich(o, all)` is O(n²) only if you can
# see that enrich() scans. Findings are still restricted to the edited file's
# changed lines (the checker treats the first path as the target). Capped, because
# this runs on every edit.
ctx_files = []
try:
    ext = os.path.splitext(path)[1].lower()
    fam = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"} if ext != ".py" else {".py"}
    cap = int(os.environ.get("SERGE_ALGO_CONTEXT_FILES", "40") or 40)
    srcdir = os.path.dirname(os.path.abspath(path)) or "."   # NOT `d` — that is the payload
    for nm in sorted(os.listdir(srcdir)):
        p = os.path.join(srcdir, nm)
        if p == os.path.abspath(path) or os.path.splitext(nm)[1].lower() not in fam:
            continue
        if os.path.isfile(p) and os.path.getsize(p) < 400_000:
            ctx_files.append(p)
        if len(ctx_files) >= cap:
            break
except Exception:
    ctx_files = []

try:
    r = subprocess.run([sys.executable, CHECKER, "all", path] + ctx_files +
                       ["--lines", ranges, "--min-sev", "low", "--json"],
                       capture_output=True, text=True, timeout=25)
    data = json.loads(r.stdout or "{}")
except Exception:
    sys.exit(0)                                       # fail open, always

order = {"low": 0, "medium": 1, "high": 2, "certain": 3}
findings = data.get("findings") or []
blocking = [f for f in findings
            if f["kind"] in ("bounds", "bigo") and order.get(f["sev"], 0) >= order.get(MIN_SEV, 2)]
fluff = [f for f in findings if f["kind"] == "fluff"]
removable = sum(f.get("cost", 0) for f in fluff)

if not blocking and removable < FLUFF_MIN:
    sys.exit(0)

# Re-blocking on a finding the model already saw and chose not to fix burns turns.
# One block per distinct finding-set per file; a changed set blocks again.
sig = hashlib.sha1(("|".join(sorted("%s:%s:%s" % (f["line"], f["kind"], f["msg"])
                                    for f in blocking)) + path).encode()).hexdigest()[:16]
guard = os.path.join(tempfile.gettempdir(),
                     "serge-algo-%s.seen" % hashlib.sha1(
                         (str(d.get("session_id") or "nosid") + path).encode()).hexdigest()[:12])

# Per-function complexity, remembered across edits to this file. This exists because
# of an observed failure: told its code was O(n²), serge added a Map cache, declared
# "O(n) performance", and was STILL O(n²) — the cache only helped duplicate keys. A
# patch that leaves the exponent where it was is the default response to this kind of
# feedback, so the gate has to be able to say "that did not move".
_FN_CX = re.compile(r"^(.+?) — est\. (O\([^)]*\))")
cur_cx = {}
for f in blocking:
    if f["kind"] == "bigo":
        m = _FN_CX.match(f["msg"])
        if m:
            cur_cx[m.group(1)] = m.group(2)

prev = {}
try:
    with open(guard) as fh:
        prev = json.loads(fh.read() or "{}")
except (OSError, ValueError):
    pass
repeat = (prev.get("sig") == sig)
stalled = [(n, c) for n, c in cur_cx.items() if prev.get("cx", {}).get(n) == c]
try:
    with open(guard, "w") as fh:
        json.dump({"sig": sig, "cx": cur_cx}, fh)
except OSError:
    pass


# Only the techniques that fit what was actually found — a generic menu on every
# block is a wall of text the model learns to skip.
LADDER = [
    ("scan|linear lookup|O\\(n²\\)|O\\(n³\\)",
     "lookup/membership inside a loop → build a dict/set/Map ONCE, then O(1): O(n·m) → O(n+m)"),
    ("scan|O\\(n²\\)",
     "pairs / duplicates / closest → sort once, then ONE linear pass or two pointers: O(n log n)"),
    ("scan|O\\(n²\\)",
     "contiguous run or window → sliding window / two pointers: O(n), not every window"),
    ("N\\+1|I/O or a query",
     "a query or request per item → ONE batched query (IN/join) or a bulk endpoint"),
    ("await inside a loop",
     "independent awaits → Promise.all / asyncio.gather with a BOUNDED concurrency"),
    ("sort inside a loop", "sort once before the loop; it is loop-invariant"),
    ("copying accumulation", "push/append into one array and join once — stop rebuilding the result"),
    ("front insert/remove", "deque (Python) or an index cursor — stop re-indexing every element"),
    ("O\\(2\\^n\\)|self-calls", "overlapping subproblems → memoize, or rewrite bottom-up as DP"),
    ("regex compiled|deep copy",
     "loop-invariant work → hoist it above the loop, compute it once"),
]


def techniques(rows):
    blob = " ".join(r["msg"] for r in rows)
    out = []
    for pat, tip in LADDER:
        if re.search(pat, blob) and tip not in out:
            out.append(tip)
    return out[:4] or ["reduce the nesting: what work in the inner loop does not depend on the outer one?"]


def render(rows):
    out = []
    for f in rows[:MAX_FIND]:
        out.append("  %s:%s  [%s] %s" % (os.path.basename(path), f["line"], f["sev"], f["msg"]))
        if f.get("fix"):
            out.append("      → %s" % f["fix"])
    if len(rows) > MAX_FIND:
        out.append("  … and %d more (run the checker for the full list)" % (len(rows) - MAX_FIND))
    return "\n".join(out)


cmdline = "python3 %s all %s --lines %s" % (CHECKER, path, ranges)

if blocking and not repeat:
    has_cost = any(f["kind"] == "bigo" for f in blocking)
    msg = ["algo_check priced the code this edit just wrote — %s before continuing:"
           % ("derive a better algorithm" if has_cost else "fix the boundary"),
           render(blocking)]

    if stalled:
        msg.append("STILL %s after your last edit to %s — the exponent did not move. A cache, an "
                   "early return, or a guard is a PATCH; the exponent only changes when the "
                   "ALGORITHM changes. Do not repeat the previous attempt."
                   % (stalled[0][1], ", ".join("`%s`" % n for n, _ in stalled)))

    if has_cost:
        msg.append("Work it out on the page BEFORE you touch the code — four lines:\n"
                   "  1. n = what actually grows here, and its realistic size.\n"
                   "  2. now = the complexity above, and WHERE it comes from (the evidence chain "
                   "names the line).\n"
                   "  3. target = the best complexity this problem allows, and the technique that "
                   "reaches it:\n"
                   + "\n".join("       - " + t for t in techniques(blocking)) +
                   "\n  4. implement THAT algorithm, then re-run the checker and quote the new "
                   "line. The exponent must actually drop; if it did not, you patched it.")

    if fluff:
        msg.append("Also removable in the same lines (~%d line%s of dead weight, not blocking):"
                   % (removable, "" if removable == 1 else "s"))
        msg.append(render(fluff))

    msg.append("If the checker is wrong here, say why in ONE line and move on — it is a syntactic "
               "estimate and it can be (a collection bounded by a constant, a callee it cannot "
               "see). Re-check with:\n  " + cmdline)
    print(json.dumps({"block": True, "text": "\n".join(msg)}))
    sys.exit(0)

# Non-blocking: material dead weight, or a repeat block downgraded to a note.
rows = blocking if repeat and blocking else fluff
if not rows:
    sys.exit(0)
head = ("Still open from the previous edit to this file (not blocking again):"
        if repeat and blocking else
        "algo_check: ~%d line%s in what you just wrote are removable without changing behavior:"
        % (removable, "" if removable == 1 else "s"))
print(json.dumps({"block": False, "text": head + "\n" + render(rows)}))
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

# Non-blocking: PostToolUse is one of the seven events that accept
# additionalContext, so the note reaches the model without costing a turn.
printf '%s' "$TEXT" | python3 -c '
import sys, json
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": sys.stdin.read(),
}}))'
exit 0
