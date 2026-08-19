#!/usr/bin/env bash
# Serge memory loader — SessionStart hook.
#
# Injects the small MEMORY.md INDEX into the session as additionalContext so Serge
# recalls its user/project facts every session — WITHOUT bloating the cached system
# prompt. The index rides in per-session context, not the constitution prefix, so it
# costs nothing in prompt-cache terms (the whole point: memory that doesn't defeat
# caching). Serge reads individual fact files on demand per the constitution's
# `## memory` rules. Also nudges a prune when the store exceeds the cap.
#
# ── THREE STORES, ONE VIEW (2026-08-14) ────────────────────────────────────
# Serge has THREE live memory stores that were not aware of each other:
#
#   A. GLOBAL / curated  — ~/.serge/memory/            (this hook has always loaded it)
#   B. PROJECT / auto    — $CLAUDE_CONFIG_DIR/projects/<sanitized-root>/memory/
#                          written by the ENGINE's own auto-memory (memdir), which
#                          the 150-line `# Memory` block of the built-in system
#                          prompt instructs the model to maintain.
#   C. PROJECT/TEAM      — .../memory/team/ — the shared half of that same block's
#                          private-vs-team split (60 files across 8 projects).
#                          Added to this loader later the same day: the A+B join
#                          used glob("<dir>/*.md"), which does not descend, so C
#                          stayed exactly as B had been — written, never read.
#
# Store B was accumulating real facts (measured 2026-08-14: 119 across 6 projects)
# that nothing ever surfaced at session start. The engine's per-turn relevance
# prefetch is gated on `tengu_moth_copse`, which is absent from the open build's
# _openBuildDefaults and therefore false (services/analytics/growthbook.ts) — so
# store B was write-mostly: the model wrote to it, and only found it again if it
# happened to go looking.
#
# They are NOT merged, deliberately. The scopes are different and both are useful:
# A is cross-project and human-curated; B is per-project and auto-extracted.
# Merging would flatten project scoping, push ~190 facts into one always-on index,
# and lose the fight anyway — the engine keeps writing to B regardless of what we
# do here. So: keep two stores, present ONE view, and state the write rule.
#
# Path resolution below mirrors src/memdir/paths.ts exactly:
#   base   = CLAUDE_CODE_REMOTE_MEMORY_DIR | CLAUDE_CONFIG_DIR | ~/.claude
#   root   = canonical git root of cwd, else cwd            (getAutoMemBase)
#   dir    = <base>/projects/<sanitize(root)>/memory/       (getAutoMemPath)
#   sanitize = s/[^a-zA-Z0-9]/-/g                           (sanitizePath)
# The engine appends a Bun.hash suffix when the sanitized name exceeds 200 chars.
# Bash cannot reproduce that hash, so we SKIP store B in that case rather than
# read a neighbouring project's memory — a wrong store is worse than no store.
#
# jq is NOT installed on this host — JSON is emitted via python3, like Serge's other
# hooks. Safe no-op when: no python3, or no memory index yet. Must exit 0 and write
# ONLY to stdout for the harness to inject the context.
set -uo pipefail

MEM_DIR="${SERGE_MEMORY_DIR:-$HOME/.serge/memory}"
INDEX="$MEM_DIR/MEMORY.md"
CAP="${SERGE_MEMORY_CAP:-100}"
# Hard ceiling on the project-index slice so a large auto-memory index cannot
# blow up every session's prompt. Chars, not tokens; ~4 chars/token.
PROJ_CAP="${SERGE_PROJECT_MEMORY_MAXCHARS:-4000}"

command -v python3 >/dev/null 2>&1 || exit 0

# SessionStart payload carries cwd; fall back to the process cwd. Never fail on it.
payload="$(cat 2>/dev/null || true)"
CWD="$(printf '%s' "$payload" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd") or "")
except Exception: print("")' 2>/dev/null)"
[ -n "$CWD" ] && [ -d "$CWD" ] || CWD="$PWD"

# Store B root: canonical git root when the cwd is in a repo, else the cwd itself.
PROJ_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || PROJ_ROOT=""
[ -n "$PROJ_ROOT" ] || PROJ_ROOT="$CWD"

MEM_BASE="${CLAUDE_CODE_REMOTE_MEMORY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"

# Nothing to inject at all? (no global index AND no project store) -> silent no-op.
[ -f "$INDEX" ] || [ -d "$MEM_BASE/projects" ] || exit 0

# Count global fact files (everything except the index) to decide on a prune nudge.
count=$(find "$MEM_DIR" -maxdepth 1 -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | wc -l | tr -d ' ')
nudge=""
if [ "${count:-0}" -gt "$CAP" ]; then
  nudge=$'\n\n[memory is over cap: '"${count}"'/'"${CAP}"' facts. Before adding more, merge or delete the stalest, lowest-value entries to get back under the cap.]'
fi

# Emit both stores as one SessionStart additionalContext (documented hook contract:
# hookSpecificOutput.additionalContext, camelCase). python3 does the path math + JSON.
INDEX="$INDEX" NUDGE="$nudge" MEM_BASE="$MEM_BASE" PROJ_ROOT="$PROJ_ROOT" \
PROJ_CAP="$PROJ_CAP" MEM_DIR="$MEM_DIR" python3 - <<'PY'
import json, os, re, glob

index_path = os.environ["INDEX"]
nudge      = os.environ.get("NUDGE", "")
mem_base   = os.environ["MEM_BASE"]
proj_root  = os.environ["PROJ_ROOT"]
mem_dir    = os.environ["MEM_DIR"]
try:
    proj_cap = int(os.environ.get("PROJ_CAP") or 4000)
except ValueError:
    proj_cap = 4000

parts = []

# ── Store A: global, curated ──────────────────────────────────────────────
try:
    with open(index_path, encoding="utf-8") as f:
        global_index = f.read()
except Exception:
    global_index = ""

if global_index:
    parts.append(
        "Serge persistent memory — GLOBAL store (cross-project, curated).\n"
        "Index below. Open the relevant fact files under ~/.serge/memory/ on demand; "
        "do not load them all. Write or update facts per the constitution's "
        "`## memory` rules.\n\n" + global_index + nudge
    )

def read_store(d):
    """Index if the engine wrote one, else a filename listing. '' when empty.

    The engine writes fact files before it writes MEMORY.md, so a store with
    real content but no index is normal — listing the filenames keeps those
    facts discoverable instead of invisible.
    """
    idx = os.path.join(d, "MEMORY.md")
    if os.path.isfile(idx):
        try:
            with open(idx, encoding="utf-8") as f:
                body = f.read().strip()
            if body:
                return body
        except Exception:
            pass
    facts = sorted(
        os.path.basename(p)
        for p in glob.glob(os.path.join(d, "*.md"))       # non-recursive: team/ excluded
        if os.path.basename(p) != "MEMORY.md"
    )
    if facts:
        return "(no index written yet) fact files:\n" + "\n".join("- " + n for n in facts)
    return ""


# ── Store B: per-project, engine auto-memory (mirrors src/memdir/paths.ts) ──
sanitized = re.sub(r"[^a-zA-Z0-9]", "-", proj_root)
if len(sanitized) <= 200:                      # MAX_SANITIZED_LENGTH; longer names
    proj_mem = os.path.join(mem_base, "projects", sanitized, "memory")
    proj_idx = os.path.join(proj_mem, "MEMORY.md")
    body = read_store(proj_mem)
    if body:
        truncated = ""
        if len(body) > proj_cap:
            body = body[:proj_cap]
            truncated = f"\n\n[project index truncated at {proj_cap} chars — read {proj_idx} for the rest]"
        parts.append(
            f"Serge persistent memory — PROJECT store for {proj_root} "
            "(auto-extracted by the engine, project-scoped).\n"
            f"Lives at {proj_mem}/. This is a SEPARATE store from ~/.serge/memory/ "
            "and both are live.\n"
            "WRITE RULE — a fact that is true only inside this project goes in the "
            "PROJECT store; a fact about the user, or one that holds across projects, "
            f"goes in the GLOBAL store ({mem_dir}/). Do not duplicate a fact into both.\n\n"
            + body + truncated
        )

    # ── Store C: the TEAM scope of the project store ─────────────────────
    # `memory/team/` is a real third store, not a variant of B. The engine
    # splits every save between private and team scope (isTeamMemoryEnabled()
    # defaults TRUE — teamMemPaths.ts:77, gate `tengu_herring_clock`, and it is
    # NOT in growthbook's _openBuildDefaults so the `true` default stands), and
    # the built-in memory prompt teaches the model to choose between them.
    # Measured 2026-08-14: 60 fact files across 8 real projects.
    #
    # B's listing above cannot reach them — glob("<dir>/*.md") does not descend —
    # so joining A and B earlier today left C exactly as B had been: written
    # every session, read by luck. Same defect, one directory deeper.
    #
    # Shares B's budget rather than getting its own: the project side of this
    # injection stays bounded by PROJ_CAP total, so surfacing C cannot grow the
    # worst-case prompt beyond what B alone was already allowed.
    team_mem = os.path.join(proj_mem, "team")
    team_cap = max(0, proj_cap - len(body))
    team_body = read_store(team_mem)
    if team_body and team_cap <= 0:
        # Budget already spent by B. Emitting nothing here would re-create the
        # exact defect this block exists to close — a populated store that the
        # session never hears about — so spend ~1 line on a pointer instead.
        n = len(glob.glob(os.path.join(team_mem, "*.md")))
        parts.append(
            f"Serge persistent memory — PROJECT/TEAM scope for {proj_root}: {n} file(s) at "
            f"{team_mem}/, not inlined (the private project index used this turn's budget). "
            "Read its MEMORY.md if project context is thin."
        )
    elif team_body:
        truncated = ""
        if len(team_body) > team_cap:
            team_body = team_body[:team_cap]
            truncated = (
                f"\n\n[team index truncated — read {os.path.join(team_mem, 'MEMORY.md')} "
                "for the rest]"
            )
        parts.append(
            f"Serge persistent memory — PROJECT/TEAM scope for {proj_root}.\n"
            f"Lives at {team_mem}/. The engine's own memory prompt splits saves "
            "between this shared scope and the private one above; on a single-user "
            "machine the split is an artifact, so treat these as project facts too — "
            "read them the same way, and prefer the private PROJECT store for new "
            "writes so facts stop scattering.\n\n"
            + team_body + truncated
        )

if not parts:
    raise SystemExit(0)

print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "\n\n---\n\n".join(parts),
}}))
PY
exit 0
