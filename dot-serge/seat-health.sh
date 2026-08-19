#!/usr/bin/env bash
# Serge seat health — catch a seat whose primary is dead but whose calls still 200.
#
# WHY: on 2026-07-28 local-coder's Mistral key was revoked (401) and all three
# Gemini rungs were quota-exhausted (429), yet every probe returned HTTP 200 —
# because the fallback chain quietly handed each request to
# nvidia/nemotron-3-super-120b-a12b:free. A dead workhorse is indistinguishable
# from a healthy one if you only look at the status code. The tell is the
# `model` field in the response body: it named a model the seat is not
# configured to use.
#
# WHAT: for each probed seat, send one 1-token request through the router and
# compare the answering model against that seat's OWN configured upstream(s).
#   OK      — answered by one of its own models
#   DRIFT   — 200, but a different model answered ⇒ a fallback is covering a dead
#             primary. This is the silent failure the script exists to catch.
#   DOWN    — non-200 / no model in the response
#   CTXFAIL — passes the 1-token probe, fails at realistic context size, and STILL
#             passes a 1-token re-probe ⇒ size is the variable. A real cap.
#   UNAVAIL — fails at size and fails the 1-token re-probe too ⇒ size is NOT the
#             variable (quota / key / outage). Split out of CTXFAIL 2026-08-14:
#             the two look identical through the router, which answers 200 from a
#             fallback either way, but their remedies are opposites — repoint the
#             seat vs. leave it alone until the bucket refills. See the block at
#             the classification site for the measurement that forced the split.
#
# WHY CTXFAIL EXISTS (2026-07-29): the 1-token probe had a blind spot that hid two
# fully dead seats. `glm-coder` and `free-scout` both point at
# `cerebras/zai-glm-4.7`, which Cerebras' free tier hard-caps at 8,192 tokens
# ("Current length is 30009 while limit is 8192"). Serge's MEDIAN request is
# ~74,700 input tokens, so those seats failed every real turn and silently fell
# through to gemini-3.1-flash-lite — while answering "hi" from Cerebras perfectly
# and reporting ok here every single day.
#
# The lesson generalises: probe at PRODUCTION shape, not minimum shape. A tiny
# probe certifies a seat that cannot do the job. Same failure family as the
# free-qwen rot, where a catalog LIST diff could not see a listed-but-refused
# model. Stage 2 sends --ctx-tokens of filler (default 12000 — above the 8k cap
# class, cheap enough to run daily) and re-checks who answered.
#
# DRIFT, DOWN and CTXFAIL append one line to ~/.serge/NOTIFICATIONS.md (deduped per
# seat per day; the SessionStart loader surfaces unchecked lines).
#
# EXIT CODES (2026-08-14) — findings and crashes must not look alike:
#   0  every probed seat answered with its own model
#   1  FINDINGS: at least one seat is drifting / down / context-capped. The check
#      ran correctly; the roster has a problem. Delivered via NOTIFICATIONS.md.
#   2  bad usage (unknown seat, non-integer --ctx-tokens)
#   3  THE CHECKER ITSELF FAILED: pyyaml missing, litellm.yaml unreadable. Nothing
#      was probed and nothing can be concluded.
#
# WHY 3 EXISTS: the systemd unit is Type=oneshot, so any non-zero exit marked the
# service `failed`. A routine finding (one capped seat) and a broken checker
# (pyyaml uninstalled) both exited 1 and were therefore indistinguishable in
# `systemctl status` — which is precisely the failure this script was written to
# catch, reproduced in the script's own reporting channel. The unit now carries
# SuccessExitStatus=1, so `failed` means "the checker broke" and findings travel
# on the channel built for them. Exit 1 is kept for findings so an interactive
# `if ! seat-health.sh` still works.
#
# Usage:
#   ~/.serge/seat-health.sh                    # the free seats that matter
#   ~/.serge/seat-health.sh --seats a,b,c      # explicit set
#   ~/.serge/seat-health.sh --all              # every free seat
#   ~/.serge/seat-health.sh --all --include-paid   # spends money, opt-in only
#   ~/.serge/seat-health.sh --quiet            # notifications only, no stdout
#   ~/.serge/seat-health.sh --ctx-tokens 75000 # full production-shape audit
#   ~/.serge/seat-health.sh --no-ctx           # stage 1 only (old behaviour)
#
# Paid seats are skipped unless --include-paid: they are detected from the
# config (api_key referencing a *PAID* env var), not a hardcoded list, so a new
# paid seat is excluded automatically.
#
# Wired as ~/.config/systemd/user/serge-seat-health.{service,timer} (daily).
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
ROUTER_URL="${SERGE_SEAT_HEALTH_URL:-http://127.0.0.1:4000/v1/chat/completions}"

SEATS=""
ALL=0
INCLUDE_PAID=0
QUIET=0
# 2026-08-14: default RAISED 12000 -> 75000 (serge's median request is ~74,700).
# 12000 was chosen as "above the 8k cap class, cheap enough to run daily" and it
# promptly created the next blind spot one size class up: cerebras/gpt-oss-120b
# caps at ~30,000 TOKENS PER MINUTE, so `qwen-coder` passed this probe at 12K and
# 429'd on every real turn — silently demoting agents/{reviewer,test,devops} and
# the whole stop-hook review path to gemini-3.1-flash-lite for weeks. A probe
# smaller than production traffic certifies seats that cannot serve production
# traffic; the only size that cannot lie is the median request size.
# Override with SERGE_SEAT_HEALTH_CTX_TOKENS or --ctx-tokens if a run gets noisy.
CTX_TOKENS="${SERGE_SEAT_HEALTH_CTX_TOKENS:-75000}"
while [ $# -gt 0 ]; do
  case "$1" in
    --seats) SEATS="${2:-}"; shift 2 ;;
    --seats=*) SEATS="${1#*=}"; shift ;;
    --all) ALL=1; shift ;;
    --include-paid) INCLUDE_PAID=1; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    --ctx-tokens) CTX_TOKENS="${2:-12000}"; shift 2 ;;
    --ctx-tokens=*) CTX_TOKENS="${1#*=}"; shift ;;
    --no-ctx) CTX_TOKENS=0; shift ;;
    -h|--help) sed -n '1,55p' "$0"; exit 0 ;;
    *) echo "seat-health: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done
case "$CTX_TOKENS" in
  ''|*[!0-9]*) echo "seat-health: --ctx-tokens must be a non-negative integer" >&2; exit 2 ;;
esac

SERGE_HOME="$SERGE_HOME" ROUTER_URL="$ROUTER_URL" SEATS="$SEATS" \
ALL="$ALL" INCLUDE_PAID="$INCLUDE_PAID" QUIET="$QUIET" CTX_TOKENS="$CTX_TOKENS" \
python3 - <<'PY'
import json, os, re, sys, time, urllib.error, urllib.request

home = os.environ["SERGE_HOME"]
url = os.environ["ROUTER_URL"]
quiet = os.environ["QUIET"] == "1"
ctx_tokens = int(os.environ.get("CTX_TOKENS", "12000"))
mon = os.path.join(home, "monitor"); os.makedirs(mon, exist_ok=True)
log_p = os.path.join(mon, "seat-health.log")
# Overridable so a test run cannot write into the live channel. The dedupe key
# is seat+date, so a stub-router test on an already-reported seat is silently
# swallowed and a test on a fresh seat plants a fabricated finding in the one
# file the SessionStart loader surfaces as truth. Point this elsewhere when
# exercising the classifier.
notif_p = os.environ.get("SERGE_NOTIFICATIONS_FILE") or os.path.join(
    home, "NOTIFICATIONS.md")
today = time.strftime("%Y-%m-%d")

# Seats worth probing when nothing is specified: the free workhorse and the
# rungs directly beneath it. Deliberately small — every probe spends free quota.
# The four Cerebras-backed seats were added 2026-07-29: they were absent from
# this list, which is the second reason the 8k-cap failure went unseen for so
# long — the seats that were broken were never probed at all.
# 2026-07-29, same lesson a third time: seven seats that AGENTS actually run on
# were still unprobed — cloud-brain (architect / reasoning / frontend-pro AND
# `serge --cloud`), bedrock-brain (security), fast-coder (scout), pro-coder
# (data / researcher), think-coder (think), search-fast (WebFetch summarizer) and
# free-large. That blind spot is why cloud-brain silently served gemini-3.1-flash-lite
# instead of its configured gemini-3.5-flash for an unknown length of time: the
# daily health check had no opinion about the brain seat. If an agent file names a
# seat, it belongs in this list.
DEFAULT_SEATS = ["local-coder", "free-flash", "free-flash3", "free-flash25",
                 "free-qwen", "free-reason", "glm-coder", "free-scout",
                 "qwen-coder", "free-brain", "cloud-brain", "bedrock-brain",
                 "fast-coder", "pro-coder", "think-coder", "search-fast",
                 "free-large"]

# ── Per-seat context expectation (2026-08-14) ────────────────────────────────
# "Probe at production shape" is right for seats whose JOB is a production-shaped
# turn. It is wrong for a seat the roster deliberately restricts to small ones:
# holding such a seat to 75,000 tokens guarantees a CTXFAIL every single day, and
# a check that always fails is a check nobody reads.
#
# free-brain (cerebras/gpt-oss-120b) is documented in litellm.yaml as "a SMALL-
# request lane only: ~30K TPM, cannot serve a full-context turn" — it is not in
# any driver fallback chain and no agent runs on it. Measured 2026-08-14 through
# this router: 8,000 tok ok (0.5s), 20,000 tok ok (0.5s), 28,000 tok times out.
# So 20,000 is the honest bar: comfortably inside the lane it is supposed to
# serve, and still a real failure if it stops serving it.
#
# This is a CEILING, not a floor — it never raises a seat above the run's
# --ctx-tokens, so `--ctx-tokens 8000` still probes everything at 8,000. Add a
# seat here only when the roster documents a smaller role for it; a seat that is
# merely FAILING at production shape belongs in the notifications, not in here.
SEAT_CTX_MAX = {
    "free-brain": 20000,
}

def log(msg):
    try:
        with open(log_p, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}\n")
    except OSError:
        pass

def out(msg):
    if not quiet:
        print(msg)

try:
    import yaml
except ImportError:
    log("FATAL pyyaml missing")
    out("seat-health: pyyaml not available"); sys.exit(3)   # checker broke, not a finding

cfg_p = os.path.join(home, "litellm.yaml")
try:
    with open(cfg_p) as f:
        cfg = yaml.safe_load(f) or {}
except (OSError, yaml.YAMLError) as e:
    log(f"FATAL cannot read {cfg_p}: {e}")
    out(f"seat-health: cannot read {cfg_p}: {e}"); sys.exit(3)  # checker broke, not a finding

# seat -> configured upstream models; a seat may have several deployments.
seats, paid = {}, set()
for entry in cfg.get("model_list", []) or []:
    name = entry.get("model_name")
    params = entry.get("litellm_params", {}) or {}
    model = params.get("model")
    if not name or not model:
        continue
    seats.setdefault(name, []).append(model)
    # Paid is derived from the key the deployment uses, not a hardcoded list,
    # so a newly added paid seat is excluded from --all automatically.
    if "PAID" in str(params.get("api_key", "")).upper():
        paid.add(name)

if os.environ["SEATS"]:
    wanted = [s.strip() for s in os.environ["SEATS"].split(",") if s.strip()]
    unknown = [s for s in wanted if s not in seats]
    if unknown:
        out(f"seat-health: unknown seat(s): {', '.join(unknown)}")
        sys.exit(2)
elif os.environ["ALL"] == "1":
    wanted = list(seats)
else:
    wanted = [s for s in DEFAULT_SEATS if s in seats]

if os.environ["INCLUDE_PAID"] != "1":
    skipped = [s for s in wanted if s in paid]
    wanted = [s for s in wanted if s not in paid]
    if skipped:
        out(f"  (skipping paid seat(s): {', '.join(sorted(set(skipped)))} — "
            f"pass --include-paid to probe them)")

def candidate_forms(configured):
    """Every shape the configured model may come back as.

    Config carries a litellm provider prefix that the response does not:
      `mistral/mistral-large-latest`         -> answered `mistral-large-latest`
      `openrouter/qwen/qwen3-coder-next`     -> answered `qwen/qwen3-coder-next`
    so accept the raw id, the prefix-stripped id, and the bare tail. Only the
    CONFIG side is decomposed — normalizing the response too would strip a real
    segment off `qwen/qwen3-coder-next` and read a healthy seat as drift.
    """
    c = (configured or "").strip().lower()
    forms = {c}
    if "/" in c:
        forms.add(c.split("/", 1)[1])
        forms.add(c.rsplit("/", 1)[1])
    return {f for f in forms if f}

def same_model(answered, configured):
    """Tolerant match: providers append suffixes (-001, dated variants) and
    litellm sometimes echoes the full configured id. Only a genuinely different
    model should read as drift."""
    a = (answered or "").strip().lower()
    if not a:
        return False
    return any(a == c or a.startswith(c) or c.startswith(a)
               for c in candidate_forms(configured))

def probe(seat, fill_tokens=0):
    """One probe. fill_tokens>0 pads the prompt to ~that many tokens so the
    request has production shape; a seat with a small hard context cap fails or
    drifts here while passing the 1-token probe."""
    if fill_tokens > 0:
        # ~10.1 tokens per repetition, measured against a real tokenizer.
        content = ("the quick brown fox jumps over the lazy dog. "
                   * max(1, fill_tokens // 10)) + " Reply OK."
    else:
        content = "hi"
    body = json.dumps({
        "model": seat,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": 1,
    }).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            payload = json.loads(r.read().decode("utf-8", "replace"))
            return r.status, payload, time.monotonic() - started, None
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:300]
        return e.code, None, time.monotonic() - started, detail
    except Exception as e:  # connection refused, timeout, bad JSON
        return None, None, time.monotonic() - started, f"{type(e).__name__}: {e}"

def notify(seat, line):
    """One line per seat per day — reruns must not spam the session loader.

    Dedup on seat+date ONLY. Keying on the full text (which names the answering
    model) silently fails: the OpenRouter free pool round-robins between
    nemotron / ling / laguna, so the same drifting seat produced a "new" line on
    every run and stacked up in NOTIFICATIONS.md.
    """
    key = f"{today} seat-health: {seat} "
    try:
        existing = open(notif_p).read() if os.path.exists(notif_p) else ""
    except OSError:
        existing = ""
    if key in existing:
        return
    try:
        with open(notif_p, "a") as f:
            f.write(f"- [ ] {line}\n")
    except OSError as e:
        log(f"WARN cannot write {notif_p}: {e}")

if not wanted:
    out("seat-health: no seats to probe"); sys.exit(0)

out(f"Serge seat health · {today} · router {url}"
    + (f" · ctx probe {ctx_tokens} tok" if ctx_tokens > 0 else " · ctx probe off"))
drift, down, ctxfail, unavail = [], [], [], []

def answered_by_self(answered, seat, configured):
    """litellm echoes the group alias when a seat is served by its own pool."""
    return (answered.strip().lower() == seat.lower()
            or any(same_model(answered, c) for c in configured))

for seat in wanted:
    configured = seats[seat]
    status, payload, secs, err = probe(seat)
    if status != 200 or not payload:
        down.append(seat)
        why = f"HTTP {status}" if status else "no response"
        out(f"  DOWN   {seat:<14} {why} ({secs:.1f}s)")
        log(f"DOWN seat={seat} status={status} detail={(err or '')[:200]}")
        notify(seat, f"{today} seat-health: {seat} DOWN — {why} "
               f"(configured: {', '.join(configured)})")
        continue

    answered = payload.get("model") or ""
    # When a seat is served by its own pool, litellm echoes the group alias
    # (`free-qwen`) instead of the underlying model id; only a fallback
    # substitutes a concrete foreign model. Alias back == healthy.
    if answered_by_self(answered, seat, configured):
        # Stage 2: same seat, production-shaped request. A seat with a hard
        # context cap below this size either errors outright or gets covered by
        # a fallback — both mean it cannot serve a real turn.
        if ctx_tokens <= 0:
            out(f"  ok     {seat:<14} {answered} ({secs:.1f}s)")
            log(f"OK seat={seat} model={answered} secs={secs:.1f}")
            continue
        # Ceiling only: a restricted seat is probed at the size its documented
        # role actually calls for, never above the run's --ctx-tokens.
        seat_ctx = min(ctx_tokens, SEAT_CTX_MAX.get(seat, ctx_tokens))
        capped = seat_ctx < ctx_tokens
        c_status, c_payload, c_secs, c_err = probe(seat, seat_ctx)
        c_answered = (c_payload or {}).get("model") or ""
        if c_status == 200 and c_payload and answered_by_self(
                c_answered, seat, configured):
            note = f"{seat_ctx} tok ok" + (" — small-request lane" if capped else "")
            out(f"  ok     {seat:<14} {answered} "
                f"({secs:.1f}s; {note}, {c_secs:.1f}s)")
            log(f"OK seat={seat} model={answered} ctx={seat_ctx}"
                f"{' capped' if capped else ''} secs={secs:.1f}")
        else:
            why = (f"answered by {c_answered}" if c_status == 200 and c_answered
                   else f"HTTP {c_status}" if c_status else "no response")
            # ── size-cap or just unavailable? (2026-08-14) ──────────────────
            # "small ok, large fails" was read as a context cap and reported as
            # one — "check the upstream's max context, not its key or quota".
            # That inference does not hold. Measured tonight: cloud-brain
            # (gemini-3.7-flash) passed at 1 token, failed at 75,000, and was
            # reported CTXFAIL — but probing the upstream DIRECTLY returned
            # `429 ... quota exceeded for metric generate_content_free_tier_
            # requests, limit: 20, model: gemini-3.7-flash`. Not a cap. A drained
            # bucket, which the router hid by falling through to free-flash3 and
            # returning 200 from it.
            #
            # The two have OPPOSITE remedies — repoint the seat vs. leave it
            # alone and wait — so guessing is worse than not classifying. Reading
            # the upstream's own error is not an option here (the fallback
            # swallows it), but ordering is enough: re-run the CHEAP probe. If
            # the seat still answers small, size is the only variable that
            # changed ⇒ cap. If it now fails small too, the seat is simply
            # unavailable and size was never the story.
            #
            # Costs one 1-token request, and only on a seat that already failed.
            r_status, r_payload, r_secs, r_err = probe(seat)
            r_answered = (r_payload or {}).get("model") or ""
            still_small_ok = (r_status == 200 and r_payload
                              and answered_by_self(r_answered, seat, configured))
            if still_small_ok:
                ctxfail.append(seat)
                out(f"  CTXFAIL {seat:<13} ok at 1 tok, fails at {seat_ctx} tok "
                    f"— {why} ({c_secs:.1f}s)")
                log(f"CTXFAIL seat={seat} ctx={seat_ctx}{' capped' if capped else ''} "
                    f"why={why} detail={(c_err or '')[:200]}")
                # A capped seat is not expected to serve a full turn, so quoting the
                # median request size at the reader would be misleading.
                consequence = (
                    f"This seat is restricted to small requests and can no longer "
                    f"serve even {seat_ctx} tokens"
                    if capped else
                    f"Serge's median request is ~74,700 tokens, so this seat cannot "
                    f"serve a real turn")
                notify(seat, f"{today} seat-health: {seat} passes a 1-token probe but "
                       f"FAILS at {seat_ctx} tokens — {why}. {consequence} "
                       f"(configured: {', '.join(configured)})")
            else:
                unavail.append(seat)
                r_why = (f"answered by {r_answered}" if r_status == 200 and r_answered
                         else f"HTTP {r_status}" if r_status else "no response")
                out(f"  UNAVAIL {seat:<13} failed at {seat_ctx} tok, and the 1-token "
                    f"re-probe failed too — {r_why} ({r_secs:.1f}s)")
                log(f"UNAVAIL seat={seat} ctx={seat_ctx} ctx_why={why} "
                    f"reprobe_why={r_why} detail={(r_err or c_err or '')[:200]}")
                notify(seat, f"{today} seat-health: {seat} UNAVAILABLE — failed at "
                       f"{seat_ctx} tokens ({why}) and then failed a 1-token re-probe "
                       f"({r_why}). Size is not the variable: this is quota, key or "
                       f"upstream outage. Do NOT repoint the seat on this evidence — "
                       f"check the bucket first (configured: {', '.join(configured)})")
    else:
        drift.append(seat)
        out(f"  DRIFT  {seat:<14} answered by {answered} "
            f"— not its own ({', '.join(configured)}) ({secs:.1f}s)")
        log(f"DRIFT seat={seat} answered={answered} "
            f"configured={'|'.join(configured)} secs={secs:.1f}")
        notify(seat, f"{today} seat-health: {seat} answered by {answered} — a fallback "
               f"is covering a dead primary ({', '.join(configured)}); "
               f"status was 200 so nothing else will flag it")

if drift or down or ctxfail or unavail:
    out("")
    if drift:
        out(f"  {len(drift)} seat(s) drifting: {', '.join(drift)}")
        out("  A drifting seat still returns 200 — check the upstream key/quota.")
    if down:
        out(f"  {len(down)} seat(s) down: {', '.join(down)}")
    if ctxfail:
        out(f"  {len(ctxfail)} seat(s) context-capped: {', '.join(ctxfail)}")
        out("  These pass a tiny probe and fail every real turn — check the")
        out("  upstream's max context, not its key or quota.")
    if unavail:
        out(f"  {len(unavail)} seat(s) unavailable: {', '.join(unavail)}")
        out("  These failed the ctx probe AND a 1-token re-probe, so size is not")
        out("  the variable — check quota/key/outage. Repointing the model here")
        out("  would swap a working seat out over a bucket that refills on its own.")
    sys.exit(1)

out("  all probed seats answered with their own model"
    + (f", including at {ctx_tokens} tokens" if ctx_tokens > 0 else ""))
sys.exit(0)
PY
