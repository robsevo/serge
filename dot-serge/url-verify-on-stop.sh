#!/usr/bin/env bash
#
# url-verify-on-stop.sh — catch FABRICATED links before the user reads them.
#
# The failure this exists for (observed 2026-07-29): serge told the user to clone
#   https://github.com/serge-ai/serge.git
# That repo does not exist — 404. The real project it pattern-matched onto is
# github.com/serge-chat/serge (a llama.cpp web UI, 200); the model kept the shape
# and invented the org. Nothing in the stack noticed, because a fabricated URL in
# PROSE is never executed: it fails only later, in the user's own terminal.
#
# That asymmetry is the whole design rationale. A made-up URL that serge *uses*
# (git clone / WebFetch / curl) is self-correcting — the tool call errors and the
# turn recovers. A made-up URL that serge merely *states* is silent, and silent is
# exactly the class the stop chain exists to close (cf. D5 silent turn, F.3
# untested-done). So this checks the final assistant TEXT, not tool calls.
#
# ── Precision over recall, deliberately ────────────────────────────────────────
# A false block is worse than the bug: it burns a turn arguing about a URL that
# was fine. So the check only ever fires on a HARD, unambiguous death:
#   - HTTP 404 / 410           (definitively not there)
#   - DNS resolution failure   (curl exit 6 — the host itself is invented)
# Everything else PASSES, including 401/403 (private repos, Cloudflare, UA walls),
# 429 (rate limit), 5xx (their outage, not our fabrication) and any timeout.
# KNOWN CONSEQUENCE: the check gets WEAKER on hosts that rate-limit us. Observed
# 2026-07-29 — after ~85 probes GitHub began answering 429 intermittently, and a
# 429 passes. A turn that emits many links to one host may therefore have some go
# unverified. That is the correct trade (a rate limit is not evidence of anything)
# but it means this check is a net, not a guarantee.
# The converse also holds and is why a 200 is never treated as proof: PyPI returns
# 200 for projects that do not exist (verified). This check can only ever say
# "this one is definitely dead", never "these are all real".
#
# ── Grounding: the signal that separates invented from merely-unvisited ────────
# Checking every URL serge prints would be both slow and wrong — most are quoted
# from something it actually read. So a URL is only a CANDIDATE when it appears in
# the final message and NOWHERE in the session's inputs: not in the user's own
# messages, not in a tool_use argument, not in a tool_result body. A URL serge read
# somewhere is grounded by definition; one that first appears in its own closing
# prose is the one that may have been generated. In practice this drops nearly
# every URL to zero network calls, which is what keeps this affordable on an
# always-on path.
#
# ── Cost ───────────────────────────────────────────────────────────────────────
# $0 (no model call). Typical turn: one regex over the final text, no URLs, exits
# in milliseconds. Worst case: MAX_CHECK URLs probed in parallel with a short
# timeout, plus a 6h on-disk verdict cache so a repeated link is never re-fetched.
#
# Disable with SERGE_URL_VERIFY=0 (house convention, cf. SERGE_QUARANTINE=0).
#
# Exit contract matches the other stop-stage checks: a single
# {"decision":"block","reason":…} on stdout re-runs the turn; exit 0 otherwise.
# Never exits non-zero on its own errors — a broken link-checker must not be able
# to wedge the stop chain.

set -uo pipefail

# Drain stdin BEFORE the kill-switch test: exiting without reading leaves the
# writer holding a closed pipe (EPIPE), which surfaced as a BrokenPipeError in the
# harness's own logs. Read first, decide second.
input="$(cat)"

[ "${SERGE_URL_VERIFY:-1}" = "0" ] && exit 0
[ -n "$input" ] || exit 0

SERGE_URL_MAX_CHECK="${SERGE_URL_MAX_CHECK:-6}" \
SERGE_URL_TIMEOUT="${SERGE_URL_TIMEOUT:-9}" \
SERGE_URL_CAP="${SERGE_URL_CAP:-12}" \
python3 - "$input" <<'PY' 2>/dev/null
import sys, json, os, re, time, hashlib, subprocess
from concurrent.futures import ThreadPoolExecutor

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

MAX_CHECK = int(os.environ.get("SERGE_URL_MAX_CHECK", "6"))
TIMEOUT   = int(os.environ.get("SERGE_URL_TIMEOUT", "6"))
CAP       = int(os.environ.get("SERGE_URL_CAP", "12"))

# ── D1 (same rule as continue-on-unfinished.sh): the harness hands us the final
#    assistant text in-band; the transcript file may not be flushed yet. ──
final_text = (d.get("last_assistant_message") or "").strip()
tx = d.get("transcript_path") or ""
have_tx = bool(tx) and os.path.exists(tx)
if not final_text and not have_tx:
    sys.exit(0)

# ── URL extraction ─────────────────────────────────────────────────────────────
# Code fences are NOT stripped: the canonical form of this bug is a fabricated
# clone line inside a ```bash block, which is precisely where the user will
# copy it from.
URL_RE = re.compile(r"""https?://[^\s<>"'`\\|)\]}]+""", re.I)

def clean(u):
    """Trim trailing punctuation a URL picks up from prose/markdown."""
    u = u.rstrip(".,;:!?'\"”’")
    # Balance parens/brackets swallowed from markdown link syntax.
    while u and u[-1] in ")]" and u.count(u[-1]) > u.count({")": "(", "]": "["}[u[-1]]):
        u = u[:-1]
    return u

def urls_in(text):
    return {clean(m.group(0)) for m in URL_RE.finditer(text or "")}

def norm(u):
    """Compare-key: scheme/case/trailing-slash/.git-insensitive."""
    u = re.sub(r"^https?://", "", u.strip(), flags=re.I).lower()
    u = re.sub(r"^www\.", "", u)
    u = u.rstrip("/")
    if u.endswith(".git"):
        u = u[:-4]
    return u

# ── Grounding set: every URL the session INPUT contained ───────────────────────
# user prose + tool_use arguments + tool_result bodies. Anything here was read,
# not generated. Also collects the final assistant text as a transcript fallback.
grounded = set()
tx_last_text = ""
if have_tx:
    try:
        with open(tx, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                # Cheap pre-filter: most rows carry no URL at all.
                has_url = "http" in line
                if not has_url and '"assistant"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                etype = e.get("type")
                m = e.get("message") or {}
                c = m.get("content")

                if etype == "user":
                    if isinstance(c, str):
                        grounded |= urls_in(c)
                    elif isinstance(c, list):
                        for b in c:
                            if not isinstance(b, dict):
                                continue
                            if b.get("type") == "text":
                                grounded |= urls_in(b.get("text", ""))
                            elif b.get("type") == "tool_result":
                                rc = b.get("content")
                                if isinstance(rc, str):
                                    grounded |= urls_in(rc)
                                elif isinstance(rc, list):
                                    for rb in rc:
                                        if isinstance(rb, dict) and rb.get("type") == "text":
                                            grounded |= urls_in(rb.get("text", ""))
                    continue

                if etype != "assistant":
                    continue
                texts = []
                for b in (c or []):
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text" and b.get("text"):
                        texts.append(b["text"])
                    elif b.get("type") == "tool_use":
                        # A URL serge PASSED to a tool was committed to and
                        # verified by that tool's success/failure — not prose.
                        grounded |= urls_in(json.dumps(b.get("input") or {}))
                if texts:
                    tx_last_text = "\n".join(texts).strip()
    except Exception:
        pass

if not final_text:
    final_text = tx_last_text
if not final_text:
    sys.exit(0)

# The final message's own URLs must not count as their own grounding.
grounded = {norm(u) for u in grounded}

# ── Candidate filter ───────────────────────────────────────────────────────────
# Documentation placeholders and non-public hosts are never fabrication.
# `.example` is a RESERVED TLD (RFC 6761) and the house style for docs samples —
# api.acme.example, gateway.acme.example, labs.acme.example all appear in
# PROG/docs/integrations/. Every one is NXDOMAIN by design. Matching only
# example.com/org/net (as this did until the 2026-07-29 sweep) missed the bare
# TLD form entirely and flagged 7 intentional placeholders as fabrications.
SKIP_HOST = re.compile(
    r"^(?:localhost|127\.|0\.0\.0\.0|\[?::1\]?|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)"
    r"|(?:^|\.)(?:example\.(?:com|org|net|edu)|example|test|invalid|localhost|local|internal)$",
    re.I,
)
PLACEHOLDER = re.compile(
    r"[<>{}$]|\.\.\.|%s|\byour[-_]|\bmy[-_]?(?:site|repo|app|domain|host|server)\b|"
    r"\b(?:xxx+|foo|bar|baz|placeholder|somewhere|username|orgname|reponame)\b",
    re.I,
)

def host_of(u):
    m = re.match(r"^https?://([^/:?#]+)", u, re.I)
    return (m.group(1) if m else "").lower()

# API-SHAPED URLs are exempt from the 404 rule entirely. The content-type test
# below catches most of them (they answer GET with JSON), but not all: exa,
# together, xiaomimimo, googleapis and opencode-zen all serve an HTML error page
# for a GET on a POST-only endpoint, which is indistinguishable from a missing
# repo page. Shape is the reliable signal.
#
# Being conservative here is nearly free. An API base URL in serge's prose is
# almost always GROUNDED (copied out of config or docs it read), so the grounding
# gate has already dropped it; and when a wrong one does slip through, the user
# gets an immediate auth/connection error rather than the silent wrong-clone this
# check exists to prevent. A false NEGATIVE on an API endpoint costs little; a
# false POSITIVE gets the whole check switched off.
API_SHAPED = re.compile(
    r"^https?://(?:api|gateway|opengateway|cloud-api|inference|generativelanguage)\.",
    re.I,
)
API_PATH = re.compile(r"/v\d+(?:beta|alpha)?(?:/|$)|/inference/|/chat/completions|/openai(?:/|$)", re.I)

def api_shaped(u):
    return bool(API_SHAPED.match(u) or API_PATH.search(u) or ".googleapis.com" in host_of(u))

candidates = []
for u in sorted(urls_in(final_text)):
    if norm(u) in grounded:
        continue
    if PLACEHOLDER.search(u):
        continue
    h = host_of(u)
    if not h or SKIP_HOST.search(h):
        continue
    candidates.append(u)

if not candidates:
    sys.exit(0)
truncated = max(0, len(candidates) - MAX_CHECK)
candidates = candidates[:MAX_CHECK]

# ── Verdict cache (6h) ─────────────────────────────────────────────────────────
CACHE = os.path.join(os.environ.get("TMPDIR", "/tmp"), "serge-urlcheck-cache.tsv")
TTL = 6 * 3600
cache, now = {}, time.time()
try:
    with open(CACHE) as fh:
        for row in fh:
            parts = row.rstrip("\n").split("\t")
            if len(parts) == 3 and now - float(parts[2]) < TTL:
                cache[parts[0]] = parts[1]
except Exception:
    pass

def probe(u):
    """-> 'dead' | 'ok'.  Only unambiguous death counts as dead."""
    key = norm(u)
    if key in cache:
        return cache[key]
    verdict = "ok"
    try:
        # -L follow redirects; a browser UA because some hosts 403 curl outright
        # (a 403 passes anyway, but the UA keeps the signal cleaner).
        r = subprocess.run(
            # --connect-timeout must stay ABOVE the libc resolver timeout (5s),
            # or an invented HOSTNAME gets cut off mid-lookup and returns exit 28
            # (timeout ⇒ pass) instead of exit 6 (NXDOMAIN ⇒ dead). Measured on
            # this box: cold NXDOMAIN takes 5.0-5.1s, because /etc/resolv.conf
            # lists four nameservers (libc honours three) and the first does not
            # answer negatively — so a 3s cap silently disabled hostname
            # detection entirely. This ceiling is only ever reached by fabricated
            # hostnames; the far commoner case, a REAL host with an invented path
            # (the 2026-07-29 github.com/serge-ai/serge bug), resolves instantly
            # and 404s in ~0.2s.
            ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}\t%{content_type}",
             "-L", "--connect-timeout", "6", "--max-time", str(TIMEOUT), "-A",
             "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36",
             u],
            capture_output=True, text=True, timeout=TIMEOUT + 4,
        )
        code, _, ctype = (r.stdout or "").strip().partition("\t")
        if r.returncode == 6:            # couldn't resolve host — invented domain
            verdict = "dead"
        elif code in ("404", "410"):
            # A 404 only means "no such page" when the host was serving PAGES.
            # API endpoints answer GET with a JSON error and work fine on POST —
            # https://opengateway.gitlawb.com/v1 returns 404 with the body
            # {"error":{"message":"Not found. Use POST /v1/chat/completions."}},
            # and api.groq.com, api.anthropic.com, cloud-api.near.ai, exa, groq,
            # fireworks, together and bedrock all behave the same. The 2026-07-29
            # codebase sweep flagged 23 such URLs, every one of them real and in
            # active use. Since this check exists for links a HUMAN will open, and
            # those are served as HTML, require text/html before calling it dead.
            # JSON or no content-type ⇒ inconclusive ⇒ pass. API-SHAPED URLs are
            # exempt regardless of content-type (see api_shaped above).
            if "text/html" in (ctype or "").lower() and not api_shaped(u):
                verdict = "dead"
    except Exception:
        verdict = "ok"                   # never block on our own failure
    cache[key] = verdict
    return verdict

try:
    with ThreadPoolExecutor(max_workers=min(6, len(candidates))) as ex:
        verdicts = list(ex.map(probe, candidates))
except Exception:
    sys.exit(0)

dead = [u for u, v in zip(candidates, verdicts) if v == "dead"]

try:
    with open(CACHE, "w") as fh:
        for k, v in cache.items():
            fh.write("%s\t%s\t%.0f\n" % (k, v, now))
except Exception:
    pass

if not dead:
    sys.exit(0)

# ── Anti-loop guard (mirrors continue-on-unfinished.sh) ────────────────────────
# Identical final text twice ⇒ the nudge didn't move serge; let the turn stop
# rather than pinning the user in a rewrite loop over one link.
sid = str(d.get("session_id") or "nosid")
base = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                    "serge-urlcheck-" + hashlib.sha1(sid.encode()).hexdigest()[:12])
cntf, hashf = base + ".cnt", base + ".last"
cur = hashlib.sha1(final_text.encode("utf-8", "ignore")).hexdigest()[:16]

def read(p, dflt=""):
    try:
        return open(p).read().strip()
    except Exception:
        return dflt

if read(hashf) == cur:
    sys.exit(0)
try:
    n = int(read(cntf, "0") or "0")
except Exception:
    n = 0
if n >= CAP:
    sys.exit(0)
try:
    open(hashf, "w").write(cur)
    open(cntf, "w").write(str(n + 1))
except Exception:
    pass

listing = "\n".join("  - %s" % u for u in dead)
extra = ("\n(%d further unverified link(s) were not checked this turn.)" % truncated) if truncated else ""
subject = ("%d links that do not exist" % len(dead)) if len(dead) > 1 else "a link that does not exist"
print(json.dumps({"decision": "block", "reason": (
    "STOP — your answer contains %s. A request to each returned "
    "404/410 or failed to resolve at all:\n%s%s\n\n"
    "These did not come from anything you read this turn — they appear nowhere in the user's "
    "message, in any tool argument, or in any tool output. You generated them, and a generated "
    "URL that merely LOOKS right is worse than no URL: the user copies it, it fails in their "
    "terminal, and the failure is yours arriving late.\n\n"
    "Fix it now, in this turn. For each dead link: look up the real one (WebSearch/WebFetch, or "
    "the package/registry metadata) and replace it, or delete it and say plainly that you do not "
    "know the correct URL. Do not guess a second time — a second invented link is the same error, "
    "not a correction. If you believe a link is genuinely valid and the check is wrong (private "
    "repo, auth-walled host), say so explicitly and state how you know it exists."
    % (subject, listing, extra)
)}))
PY
exit 0
