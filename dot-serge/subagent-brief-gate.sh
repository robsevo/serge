#!/usr/bin/env bash
# Serge subagent-brief gate — PreToolUse on Agent/Task spawns ($0, no LLM).
#
# WHY THIS EXISTS (measured, 2026-08-02, evals/graph-behavior/, 72 sessions):
# asked to split a feature across three subagents, the driver writes genuinely competent
# briefs — right objectives, clear scope, sane outputs — and carries NONE of the operational
# constraints sitting in the repo it just read. It briefed an agent to add a Redis process
# to a box whose DEPLOY.md says "any new long-running process must stay under 128 MB RSS"
# without mentioning the ceiling, and specified Jest in a repo whose CONTRIBUTING.md says
# CI fails the build if `jest` appears anywhere. Baseline 0/6.
#
# Prose does not fix this. The constitution already says the brief is the subagent's entire
# world; graph-directive.sh says it again at the top of every orchestration turn, with an
# explicit "look before you brief" step. A/B: 0/6 → 1/6. That is noise. The reminder ARRIVES
# (probe-verified: the model answers YES to "did you receive a system-reminder containing
# GRAPH ENGINEERING") — it just doesn't survive to the artifact several tool calls later.
#
# So this moves the check from prompt time to SPAWN time, where the brief actually exists.
#
# IT ATTACHES, IT DOES NOT ARGUE. v1 denied and asked the model to revise; measured
# end-to-end that landed 5/12 (vs 0/8 with no gate) — better than the reminder, still
# coin-flip, because a denied brief was sometimes re-issued unchanged or "revised" without
# the constraint. PreToolUse can return `updatedInput` (applied on an `allow`), so the gate
# now WRITES the constraint onto the edge itself and lets the spawn through. No extra turn,
# no reliance on compliance, and the subagent cannot start without the ceiling in hand.
#
# WHAT IT CHECKS (all deterministic, no intent heuristics):
#   The repo states hard constraints (must/never/do not/fails the build + a distinctive
#   token like `128`, `jest`, a backticked identifier) in its constraint docs, the brief
#   asks a subagent to CHANGE something, and the brief mentions none of the tokens of a
#   SEVERE one (resource ceiling or outright ban) → append those lines to the brief.
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   - Discovery briefs (find/map/locate/list/investigate) are exempt — a scout does not
#     need the RAM ceiling, and padding every brief buries the signal.
#   - Only SEVERE constraints force an attach. Style/branching/layout rules are left alone:
#     measured, "brief mentions ANY constraint token" let a brief that named port 8080
#     through while the RAM ceiling never crossed.
#   - It never judges RELEVANCE, and never rewrites what the model wrote — it only appends
#     a clearly-labelled block, capped at 3 lines, and never stacks a second one.
#
# Safety:
#   1. Off-switch: SERGE_BRIEF_GATE_DISABLE=1
#   2. Fail open on ANY error — a scan that didn't finish cannot prove an omission.
#   3. Reads only known constraint docs at repo root + docs/ (≤12 files, ≤256 KB).
#   4. Only the workspace root (cwd) is scanned. No network, no other projects.
#
# Wired in ~/.serge/settings.json as PreToolUse "Agent|Task".
# Companion: skills/graph-engineering/SKILL.md · evals/graph-behavior/
set -uo pipefail

[ "${SERGE_BRIEF_GATE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

python3 - "$input" <<'PY'
import sys, json, os, re, math

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "PreToolUse":
    sys.exit(0)
if str(d.get("tool_name") or "") not in ("Agent", "Task"):
    sys.exit(0)

# Diagnostic log (opt-in): SERGE_BRIEF_GATE_LOG=/path/to.jsonl
# The hook only runs on Agent|Task, so an EMPTY log across a task that was supposed to
# delegate proves the model never spawned a subagent at all — which is a different
# failure from the gate deciding not to act. Used to separate those two in evals.
LOGP = os.environ.get("SERGE_BRIEF_GATE_LOG") or ""
def log(**kw):
    if not LOGP:
        return
    try:
        kw.setdefault("tool", str(d.get("tool_name") or ""))
        with open(LOGP, "a") as fh:
            fh.write(json.dumps(kw) + "\n")
    except Exception:
        pass

ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    sys.exit(0)

brief = ti.get("prompt")
# 120 was far too high: real briefs for small changes measured 74 and 90 chars and skipped
# the gate entirely. A short brief is if anything MORE likely to omit a ceiling. 40 only
# excludes a genuinely contentless spawn.
if not isinstance(brief, str) or len(brief.strip()) < 40:
    log(decision="skip", why="brief-too-short",
        n=len(brief.strip()) if isinstance(brief, str) else -1)
    sys.exit(0)  # contentless spawn — nothing to omit

# --- discovery briefs are exempt; everything else gets the constraints -------
# v1 required a CHANGE verb from a whitelist and skipped otherwise. Measured: the model
# wrote "append the line ..." — not on the list — so a genuine change brief was silently
# classified as discovery and skipped (2 of 6 eval runs, which I had misread as "the model
# never spawned"). A verb whitelist is always incomplete, so the DEFAULT is now to attach:
# only a brief that is CLEARLY discovery-only is exempt. Over-attaching costs ≤3 labelled
# lines in a brief; under-attaching costs a subagent shipping against a limit it never saw.
# "Do not change any code" is a discovery brief. "…and stop without changing any OTHER
# file" is a change brief that scopes itself — matching it cost 6/6 attaches in an eval
# round before the lookahead was added.
NO_CHANGE = re.compile(r"""\b(?:do\s+not|don't|never|without)\s+
                            (?:chang\w+|modify\w*|edit\w*|alter\w*|writ\w+|implement\w*|
                               creat\w+|touch\w*|updat\w+)
                            # \b is load-bearing: without it the engine backtracks
                            # `chang\w+` to "changin", leaving "g" — not whitespace — so
                            # the lookahead below passes trivially and the exemption fires
                            # on exactly the briefs it was meant to let through.
                            \b
                            (?!\s+(?:any\s+other|any\s+further|anything\s+else|other|
                                     others|another|additional|further|the\s+rest))""",
                       re.I | re.X)
# Verb forms only. `migrat\w+` also matched the NOUN in "plan the migration in a later
# step" — a pure discovery brief — and the same trap applies to creation/configuration.
CHANGEV = re.compile(r"""\b(implement\w*|writ(?:e|es|ing)|add(?:s|ing)?|append\w*|insert\w*|
                           creat(?:e|es|ing)|build\w*|refactor\w*|fix(?:es|ing)?|
                           updat(?:e|es|ing|ed)|modif(?:y|ies|ying)|edit(?:s|ing)?|
                           alter(?:s|ing)?|appl(?:y|ies|ying)|extend\w*|adjust\w*|patch\w*|
                           migrat(?:e|es|ing)|install\w*|configur(?:e|es|ing)|wire\w*|
                           renam\w+|delet(?:e|es|ing)|remov(?:e|es|ing)|replac(?:e|es|ing)|
                           introduc\w+|scaffold\w*|set\s+up|hook\s+up|make|ensure)\b""",
                     re.I | re.X)
DISCOVERV = re.compile(r"""\b(find|locate|search|map|list|enumerate|inspect|investigate|
                             survey|identify|report|summar\w+|audit|review|trace)\b""",
                       re.I | re.X)

# A discovery brief is exempt from the CONSTRAINT block only — it is not exempt from the
# hook. A scout's zone knowledge is the most valuable thing the persistence loop can
# collect, and memory lessons help it search in the right place, so both still apply.
is_discovery = bool(NO_CHANGE.search(brief)
                    or (DISCOVERV.search(brief) and not CHANGEV.search(brief)))

root = os.path.abspath(os.path.expanduser(str(d.get("cwd") or ".")))
if not os.path.isdir(root):
    log(decision="skip", why="no-cwd")
    sys.exit(0)

# --- collect constraint docs ------------------------------------------------
NAMES = re.compile(r"""^(deploy|deployment|contributing|claude|agents|architecture|
                         ops|operations|runbook|conventions|standards|style|
                         readme|hacking|development|setup)
                       (\.[a-z]+)?\.(md|markdown|rst|txt)$""", re.I | re.X)
MAX_FILES, MAX_BYTES = 12, 256 * 1024

docs, total = [], 0
try:
    cands = []
    for entry in sorted(os.listdir(root)):
        if NAMES.match(entry) and os.path.isfile(os.path.join(root, entry)):
            cands.append(os.path.join(root, entry))
    docsdir = os.path.join(root, "docs")
    if os.path.isdir(docsdir):
        for entry in sorted(os.listdir(docsdir))[:20]:
            p = os.path.join(docsdir, entry)
            if NAMES.match(entry) and os.path.isfile(p):
                cands.append(p)
    for p in cands[:MAX_FILES]:
        sz = os.path.getsize(p)
        if total + sz > MAX_BYTES:
            break
        total += sz
        with open(p, "r", errors="ignore") as fh:
            docs.append((p, fh.read().splitlines()))
except Exception:
    sys.exit(0)  # incomplete scan proves nothing

# No constraint docs is NOT a reason to stop: the memory block below is independent of
# whether this repo happens to ship a DEPLOY.md.
have_docs = bool(docs)

# --- extract hard constraint lines + their distinctive tokens ---------------
HARD = re.compile(r"""\b(must\s+(?:not\s+|never\s+)?(?:stay|be|use|remain|not|never|run|keep|
                                                      exceed|go|have|include|match|follow)?
                     |never\s+(?:add|use|commit|run|write|call|import|exceed|bind)
                     |do\s+not\s+(?:add|use|commit|run|write|call|import|exceed|bind|create)
                     |don't\s+(?:add|use|commit|run|write|call|import|exceed|bind)
                     |forbidden|banned|prohibited|not\s+allowed
                     |fails?\s+the\s+build|will\s+fail|hard\s+(?:limit|max|cap)
                     |at\s+most|no\s+more\s+than|under\s+\d|required\s+to)\b""", re.I | re.X)

# A token is "distinctive" if a brief that knew the constraint would plausibly contain it.
# `=` and `:` are in the charset so CLI flags and env assignments tokenize whole —
# `--max-old-space-size=128`, `NODE_ENV=production`, `maxmemory:256mb` are exactly the
# shape a deploy doc states a ceiling in, and without them the token was simply lost.
TOKEN = re.compile(r"`([A-Za-z0-9_.\-/=:]{2,48})`"         # `backticked`
                   r"|\*\*([A-Za-z0-9_.\-/=: ]{2,48})\*\*"  # **bolded**
                   r"|\b(\d{2,6})\s*(MB|GB|KB|ms|s|m|%|)\b")  # 128 MB, 90, 512

STOP = {"the", "and", "for", "not", "use", "run", "add", "npm", "git", "this", "that",
        "with", "from", "you", "your", "are", "was", "has", "its", "it's", "all", "any",
        "one", "two", "new", "old", "our", "per", "via", "see", "read", "main", "true",
        "false", "null", "none", "yes", "no", "10", "20", "30", "60", "100"}

# Real docs wrap constraints across lines ("CI now fails\nthe build if `jest`..."), so
# match SENTENCES rebuilt from paragraphs, not raw lines. Headings, blank lines and code
# fences break a paragraph; the hit is attributed to the line the sentence starts on.
# Splitting naively on [.!?] tears identifiers apart: `PROOF.txt`, `package.json` and
# `lib/api.ts` all end a "sentence" mid-token, the backtick never closes, and the constraint
# silently yields no tokens (measured — a probe constraint naming `PROOF.txt` extracted
# nothing). A period only terminates when what follows is whitespace/end, allowing for
# trailing markdown emphasis so "**... 128 MB RSS.**" still terminates correctly.
_TERM = re.compile(r"[.!?]+")
_ENDS = re.compile(r"[*_)\]\"']*(?:\s|$)")

def sentences(text):
    """Yield (offset, sentence) with dotted identifiers kept intact."""
    start = 0
    for m in _TERM.finditer(text):
        if _ENDS.match(text[m.end():]):
            yield start, text[start:m.end()]
            start = m.end()
    if start < len(text):
        yield start, text[start:]

def blocks(lines):
    """Yield (joined_text, [(char_offset, lineno)]) per paragraph."""
    buf, offs, fence = [], [], False
    for i, line in enumerate(lines, 1):
        s = line.strip()
        if s.startswith("```") or s.startswith("~~~"):
            fence = not fence
            s = ""
        if fence:
            continue
        if not s or s.startswith("#"):
            if buf:
                yield " ".join(buf), offs
            buf, offs = [], []
            continue
        s = re.sub(r"^([-*+]|\d+\.)\s+", "", s)  # strip list markers
        offs.append((sum(len(x) + 1 for x in buf), i))
        buf.append(s)
    if buf:
        yield " ".join(buf), offs

hits = []   # (path, lineno, text, tokens)
for path, lines in (docs if (have_docs and not is_discovery) else []):
    for text, offs in blocks(lines):
        if len(text) > 4000:
            continue
        for soff, raw in sentences(text):
            s = raw.strip()
            if not s or len(s) > 400 or not HARD.search(s):
                continue
            toks = set()
            for tm in TOKEN.finditer(s):
                t = (tm.group(1) or tm.group(2) or tm.group(3) or "").strip().lower()
                if t and t not in STOP and len(t) >= 2:
                    toks.add(t)
            if not toks:
                continue
            ln = offs[0][1] if offs else 1
            for off, lineno in offs:
                if off <= soff:
                    ln = lineno
                else:
                    break
            hits.append((path, ln, s, toks))

# (no hard constraints found is fine — memory may still apply)

# --- which constraints failed to cross? -------------------------------------
# Measured 2026-08-02: "brief mentions ANY constraint token" is too lenient. A brief that
# happened to name port 8080 satisfied the check while the RAM ceiling — the constraint
# that would actually break production — never crossed. The gate fired on only 2 of 4
# eval runs for exactly this reason, and passed 2/2 when it did fire.
#
# So check EACH constraint independently, and only force the issue for SEVERE ones:
# resource ceilings and outright bans. Style, branching and layout rules are left alone —
# gating those would train the model to pad every brief, which buries the signal it needs.
SEVERE = re.compile(r"""\b(RSS|OOM|RAM|memory|MB|GB|connections?|hard\s+(?:limit|max|cap)
                          |never|banned|forbidden|prohibited|not\s+allowed
                          |fails?\s+the\s+build|will\s+fail|OOM-?killed)\b""", re.I | re.X)

low = brief.lower()
def mentioned(tok):
    return re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(tok), low) is not None

missing = [h for h in hits if SEVERE.search(h[2]) and not any(mentioned(t) for t in h[3])]
hits = missing

# --- ATTACH, don't argue ----------------------------------------------------
# v1 denied and asked the model to revise. Measured: it complied about half the time —
# a denied brief was sometimes re-issued unchanged (block-once then let it through) or
# revised without the constraint. Since PreToolUse can return `updatedInput` (applied on
# an `allow`), the gate simply WRITES the constraint onto the edge itself. No extra turn,
# no reliance on compliance, and the subagent cannot be spawned without it.
# --- serge's own memory: the other thing a subagent is blind to --------------
# repo-card.sh gives a subagent the repo's STRUCTURE and the block above gives it the
# repo's CONSTRAINTS. Neither gives it serge's accumulated LESSONS — the hard-won facts in
# ~/.serge/memory that the driver would use itself and that a cold seat re-learns the
# expensive way. Same lever, same reason it works: put the fact on the edge rather than
# hoping the brief-writer remembers it.
#
# Cheap relevance only: distinctive-token overlap between the brief and each memory's
# frontmatter name+description (frontmatter only — bodies are 2-8 KB and would swamp a
# brief). Top 2, and only above a floor, so an unrelated spawn attaches nothing.
MEMDIR = os.path.expanduser("~/.serge/memory")
# No dot in the class: `client.` and `client` must be the same token (they weren't, and
# nothing matched). Crude plural/tense stemming, because "blanks" vs "blank" otherwise miss.
_WORD = re.compile(r"[a-z][a-z0-9_-]{3,}")
_SKIP = {"this", "that", "with", "from", "your", "when", "then", "than", "into", "such",
         "have", "been", "will", "must", "they", "them", "what", "which", "where", "there",
         "these", "those", "their", "here", "only", "also", "some", "each", "every", "same",
         "file", "code", "test", "return", "report", "write", "read", "make", "just",
         "does", "done", "need", "using", "used", "like", "back", "serge", "agent",
         "brief", "task", "work", "repo", "repository", "project", "add", "fix"}

def _stem(w):
    w = w.strip("-_")
    for suf in ("ing", "ed", "es", "s"):
        if len(w) > 5 and w.endswith(suf):
            return w[:-len(suf)]
    return w

def _toks(s):
    return {_stem(w) for w in _WORD.findall(s.lower())} - _SKIP

# Tuned on serge's real 57-memory corpus against 3 relevant and 3 unrelated briefs:
# a CORRECT match overlaps >=3 distinctive tokens; noise overlaps exactly 1. Requiring
# both a token count and an IDF floor keeps precision high at the cost of recall — a miss
# leaves the subagent exactly as blind as it is today, whereas a wrong memory actively
# misleads it, so the asymmetry is deliberate.
MEM_MIN_TOKENS, MEM_MIN_SCORE, MEM_MAX = 3, 6.0, 2

mem_hits = []
try:
    brief_toks = _toks(brief)
    if brief_toks and os.path.isdir(MEMDIR):
        entries = []
        for fn in sorted(os.listdir(MEMDIR)):
            if not fn.endswith(".md") or fn == "MEMORY.md":
                continue
            try:
                with open(os.path.join(MEMDIR, fn), "r", errors="ignore") as fh:
                    head = "".join(fh.readline() for _ in range(14))
            except Exception:
                continue
            dm = re.search(r"^description:\s*(.+)$", head, re.M)
            if dm:
                entries.append((fn, dm.group(1).strip(), _toks(fn[:-3] + " " + dm.group(1))))
        n_docs = len(entries)
        if n_docs >= 5:
            df = {}
            for _, _, t in entries:
                for w in t:
                    df[w] = df.get(w, 0) + 1
            for fn, desc, t in entries:
                ov = brief_toks & t
                if len(ov) < MEM_MIN_TOKENS:
                    continue
                score = sum(math.log(n_docs / (1.0 + df.get(w, 0))) for w in ov)
                if score >= MEM_MIN_SCORE:
                    mem_hits.append((score, fn, desc))
            mem_hits.sort(key=lambda x: (-x[0], x[1]))
            mem_hits = mem_hits[:MEM_MAX]
except Exception:
    mem_hits = []  # memory is a bonus; never let it break a spawn

# --- the seat-note ask rides the BRIEF, not a reminder ----------------------
# seat-notes.sh injects a seat's past notes at SubagentStart (proven to arrive: a seeded
# codeword the subagent could not otherwise know came back in its answer). But the ASK to
# produce a new note has to survive into the report the subagent writes many tool calls
# later, and a reminder measurably does not do that — three live runs harvested nothing,
# including one that wrote 1600 chars about a genuine two-incident bug. The brief is the
# subagent's instruction sheet and `updatedInput` was measured to change its output, so the
# ask goes here. Costs ~50 tokens on a spawn; the whole persistence loop depends on it.
ZONE_ASK = (
    "\n\n## Required last line\n"
    "Whatever else you write, end your final report with exactly one line:\n"
    "  ZONE NOTE: <one sentence a future agent working in this same area would want>\n"
    "Use `ZONE NOTE: NONE` if nothing durable came up. Good notes are gotchas, where "
    "something actually lives, a command that really works, or an approach that failed and "
    "why — not a summary of what you did."
)
want_ask = "ZONE NOTE" not in brief

if not hits and not mem_hits and not want_ask:
    log(decision="skip", why="nothing-to-attach")
    sys.exit(0)

HEADER = "## Repo constraints (auto-attached by serge from this repo's docs)"
MEMHEADER = "## Prior lessons (auto-attached from serge's memory)"

if HEADER in brief or MEMHEADER in brief:
    log(decision="skip", why="already-attached")
    sys.exit(0)  # already carries an attachment — never stack them

attachment = ""
if hits:
    shown = []
    for path, ln, text, _ in hits[:3]:
        rel = os.path.relpath(path, root)
        shown.append("- %s (%s:%d)" % (text if len(text) <= 240 else text[:237] + "...", rel, ln))
    extra = ("\n- ... and %d more constraint line(s) in that file — read it if this job "
             "touches them." % (len(hits) - 3)) if len(hits) > 3 else ""
    attachment += (
        "\n\n" + HEADER + "\n"
        "You cannot see this repository's docs, so these were pulled from them for you. They "
        "are binding on the work in this brief:\n\n"
        + "\n".join(shown) + extra +
        "\n\nIf your solution would violate any of these, stop and say so in your report "
        "instead of shipping around it."
    )
if want_ask:
    attachment += ZONE_ASK
if mem_hits:
    attachment += (
        "\n\n" + MEMHEADER + "\n"
        "You run without serge's memory. These previously-learned facts look relevant to "
        "this job — treat them as prior observations to verify, not as live state:\n\n"
        + "\n".join("- %s\n  (full note: ~/.serge/memory/%s)" % (d, f) for _, f, d in mem_hits)
    )

new_input = dict(ti)
new_input["prompt"] = brief + attachment

log(decision="attach", n=len(hits), mem=len(mem_hits),
    ask=bool(want_ask), discovery=is_discovery)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason":
        "Enriched the brief: %d repo constraint(s)%s%s. A subagent sees nothing but its "
        "brief, so an omitted ceiling produces confident, well-formed, wrong work with "
        "nothing raising an error."
        % (len(hits),
           " from " + ", ".join(sorted({os.path.relpath(h[0], root) for h in hits[:3]})) if hits else "",
           " + %d memory note(s)" % len(mem_hits) if mem_hits else ""),
    "updatedInput": new_input,
}}))
sys.exit(0)
PY
exit 0
