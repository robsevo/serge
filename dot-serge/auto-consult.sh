#!/usr/bin/env bash
# Serge auto-consult — UserPromptSubmit hook that gives HARD turns a native-reasoner
# pass BEFORE the driver acts, then folds that reasoning into the turn as context.
#
# WHY: the default workhorse (local-coder = Mistral Large) is a non-reasoner, and the one
# free seat that reasons natively AND well — think-coder (Magistral Medium) — CANNOT drive
# Claude Code's agentic tool loop (smoke-tested 2026-07-15: on a trivial "read this file,
# reply with the number" task Magistral never issued the Read call, emitted chat-style
# reasoning and stalled; Mistral answered correctly). So Magistral can't be the workhorse
# OR the escalation driver. This hook uses it the ONE way it's good at — a read-only,
# single-shot REASONING consultant — and injects its analysis so a PROVEN driver
# (Mistral/Gemini) still runs the tools. It's the automatic form of /deepthink's consult,
# gated to the same turns the escalation classifier calls hard.
#
# FLOW: UserPromptSubmit fires once per human turn -> read the prompt on stdin -> if it
# matches the hard-task regex (SERGE_CLASSIFIER_REGEX, the SAME one the classifier uses)
# -> one reasoning_effort=high call to think-coder via the router -> emit the analysis as
# hookSpecificOutput.additionalContext. Easy turns: no-op, zero added latency.
#
# FAIL-OPEN: any error / timeout / router-down / non-hard turn -> print nothing, exit 0.
# The turn ALWAYS proceeds; a missing consult never blocks the user. The internal call is
# capped (SERGE_CONSULT_MAXTIME=75s) UNDER the hook's settings.json timeout (90s) so the
# internal timeout fires first and fails open, rather than the hook being hard-killed.
#
# KNOBS (serge.env): SERGE_AUTOCONSULT=0 disables · SERGE_CONSULT_MODEL=<seat> (default
# think-coder) · SERGE_CONSULT_MAXTIME=<sec>. Uses the SAME Mistral pool the workhorse
# already sends every prompt to — no new data-exposure surface. Wired as a UserPromptSubmit
# command hook in ~/.serge/settings.json.
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
PAYLOAD="$(cat 2>/dev/null || true)"   # the UserPromptSubmit hook JSON arrives on stdin

# Kill switch — bail before doing any work.
[ "${SERGE_AUTOCONSULT:-1}" = "0" ] && exit 0

PAYLOAD="$PAYLOAD" \
SERGE_HOME="$SERGE_HOME" \
SERGE_CONSULT_MODEL="${SERGE_CONSULT_MODEL:-think-coder}" \
SERGE_CONSULT_REGEX="${SERGE_CONSULT_REGEX:-${SERGE_CLASSIFIER_REGEX:-}}" \
SERGE_CONSULT_URL="${OPENAI_BASE_URL:-http://localhost:4000/v1}/chat/completions" \
SERGE_CONSULT_MAXTIME="${SERGE_CONSULT_MAXTIME:-75}" \
python3 - <<'PY'
import json, os, re, sys, urllib.request

# Harness plumbing is not a user turn. Strip <system-reminder> AND <task-notification>
# blocks (background-task completions arrive through UserPromptSubmit): 13 of 45 consults on
# 2026-07-21 fired on task notifications — wasted free-tier quota and added latency before
# every background completion. If nothing user-authored remains, this is not a turn to act on.
_WRAPPERS = r"<system-reminder>.*?</system-reminder>|<task-notification>.*?</task-notification>|\[SYSTEM NOTIFICATION[^\]]*\]"

LOG = os.path.join(os.environ.get("SERGE_HOME", os.path.expanduser("~/.serge")),
                   "monitor", "auto-consult.log")

def log(msg):
    # Observability into when the consult fires / fails open. Fail-open on IO too.
    try:
        import time
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "  " + msg + "\n")
    except Exception:
        pass

def bail():
    # Fail-open: emit nothing (no additionalContext), let the turn proceed.
    sys.exit(0)

def main():
    try:
        data = json.loads(os.environ.get("PAYLOAD") or "{}")
    except Exception:
        bail()

    prompt = (data.get("prompt") or "").strip()
    if not prompt:
        bail()

    # Strip harness-injected <system-reminder> blocks before classifying — the escalation
    # classifier does the same, so the consult keys on the user's words, not scaffolding.
    clean = re.sub(_WRAPPERS, " ", prompt, flags=re.S).strip()

    # Skip slash-commands and oversized pastes (context dumps, not reasoning questions).
    if not clean or clean.startswith("/") or len(clean) > 12000:
        bail()

    HARD_DEFAULT = (
        r"\b(architect(?:ure|ural|ing)?|re-?architect|re-?design|re-?structure|restructure|"
        r"trade-?offs?|race conditions?|dead-?locks?|concurren(?:t|cy)|thread-?safe|"
        r"data races?|memory leaks?|heisenbugs?|non-?deterministic|root[- ]cause|"
        r"security (?:vulnerab|flaw|hole|review|audit)|vulnerabilit(?:y|ies)|exploit|"
        r"sql injection|auth(?:n|z)? bypass|cryptograph(?:y|ic|ically)?|"
        r"distributed (?:system|transaction|lock)|consensus algorithm|"
        # These three were written as STEMS but the group's trailing \b killed them:
        # `idempoten\b` cannot match "idempotency" (no boundary between n and c), so
        # every idempotency/cryptography/verification turn — the exact vocabulary
        # this detector exists for — silently skipped the consult. Suffixes are now
        # explicit instead of relying on a boundary that can never fire.
        r"idempoten(?:t|cy|ce)?|formal(?:ly)? verif(?:y|ied|ication|ications)?|"
        r"prove (?:that|why|it|the))\b"
    )
    pat = os.environ.get("SERGE_CONSULT_REGEX") or HARD_DEFAULT
    try:
        rx = re.compile(pat, re.I)
    except re.error:
        try:
            rx = re.compile(HARD_DEFAULT, re.I)
        except re.error:
            bail()
    if not rx.search(clean):
        bail()   # not a hard turn -> no consult, no latency

    system = (
        "You are Serge's reasoning specialist, consulted automatically before the "
        "implementer acts on a hard request. You see ONLY the user's request text — not the "
        "codebase, the tools, or the conversation history — so reason about the PROBLEM, not "
        "repo specifics. Reason from first principles and show the load-bearing steps "
        "compactly. State what is actually being asked, the key considerations and tradeoffs, "
        "and the most tempting-but-wrong approach. Pressure-test the obvious answer: name the "
        "boundary case or assumption that could make it wrong. Be decisive and tight; do NOT "
        "write code — the implementer acts on your analysis. End with exactly: RECOMMENDATION "
        "— one decisive line; BIGGEST RISK — the single thing most likely to make this wrong "
        "and how to check it; CONFIDENCE — high / medium / low. "
        # 2026-08-15 — the latency fix. This hook blocks the prompt, so its
        # output length IS the user's wait, and the prompt had no length budget:
        # measured 50 words one run and 219 the next on the SAME question, 5.8s
        # vs 10.9s, and up to 33s when it ran long. Capping max_tokens instead
        # just truncated it (finish_reason "length", analysis cut mid-thought) —
        # a shorter COMPLETE answer beats a chopped-off long one. With the budget:
        # 1.9s and 1.9s, ~100 words, finish "stop", both runs. Roughly 3-5x
        # faster and, more importantly, predictable.
        "HARD LENGTH BUDGET: at most 150 words before the three closing lines. "
        "Clipped bullets, not prose. No preamble, no restating the question, no "
        "headings. The implementer is waiting on you — brevity is part of the job."
    )

    body = json.dumps({
        "model": os.environ.get("SERGE_CONSULT_MODEL", "think-coder"),
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": clean},
        ],
        # 2026-07-29: was 1500. think-coder (Magistral) is a dedicated reasoner —
        # measured EMPTY `content` with finish_reason "length" at 1500 AND at 4000
        # on a hard question. The consult survives only because the harvest below
        # falls back to reasoning_content (production log: 74 consults, 0 empty).
        # 2500 buys real prose instead of raw thinking on mid-weight questions.
        "max_tokens": 2500,
        # 2026-08-15: "high" -> "medium", and this is NOT a quality trade — at
        # high effort Magistral spends the max_tokens budget on hidden reasoning
        # and has little left for the answer. Measured twice on the same hard
        # question, same 2500 cap:
        #   high    17.4s / 21.4s   reasoning 9.4KB / 9.7KB   PROSE 1130B / 939B
        #   medium  12.4s / 16.2s   reasoning 6.8KB / 7.8KB   PROSE 1671B / 1193B
        # Medium is ~25-30% faster AND returns more usable prose, because the
        # thinking is what was crowding it out. That is the same mechanism as the
        # note above (empty `content`, finish_reason "length") — raising the cap
        # treated the symptom; lowering the effort removes the cause.
        # SERGE_CONSULT_EFFORT overrides.
        "reasoning_effort": os.environ.get("SERGE_CONSULT_EFFORT", "medium"),
        "stream": False,
    }).encode()

    req = urllib.request.Request(
        os.environ["SERGE_CONSULT_URL"], data=body,
        headers={"Content-Type": "application/json", "Authorization": "Bearer sk-noop"},
    )
    try:
        maxt = float(os.environ.get("SERGE_CONSULT_MAXTIME", "75"))
    except ValueError:
        maxt = 75.0
    try:
        with urllib.request.urlopen(req, timeout=maxt) as resp:
            r = json.load(resp)
    except Exception as e:
        log("fail-open call-error=%s q=%r" % (type(e).__name__, clean[:80]))
        bail()   # router down / timeout / any error -> fail-open

    try:
        msg = r["choices"][0]["message"]
        analysis = (msg.get("content") or "").strip() or (msg.get("reasoning_content") or "").strip()
    except (KeyError, IndexError, TypeError):
        log("fail-open malformed-response q=%r" % (clean[:80],))
        bail()
    if not analysis:
        log("fail-open empty-analysis q=%r" % (clean[:80],))
        bail()
    # Substance floor. "Non-empty" is not the same as "useful": 3 of the first 74
    # production consults delivered 38-40 BYTES — a starved reasoner emitting a
    # fragment, which passed the check above and then spent context telling the
    # driver nothing. A consult that short cannot pressure-test anything.
    if len(analysis) < int(os.environ.get("SERGE_CONSULT_MIN_BYTES", "200")):
        log("fail-open thin-analysis bytes=%d q=%r" % (len(analysis), clean[:80]))
        bail()

    ctx = (
        "[auto-consult] Before you act, an independent reasoning model (think-coder / "
        "Magistral) analyzed this request. It saw ONLY the request text — not the codebase, "
        "tools, or history — so treat it as a strong reasoning prior to pressure-test your "
        "own approach against, and VERIFY every specific against the actual code and facts. "
        "Do not mention this consult to the user.\n\n"
        "===== reasoning-specialist analysis =====\n" + analysis +
        "\n===== end analysis ====="
    )

    log("consulted model=%s bytes=%d q=%r" % (
        os.environ.get("SERGE_CONSULT_MODEL", "think-coder"), len(analysis), clean[:80]))
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": ctx,
        }
    }))

try:
    main()
except SystemExit:
    raise
except Exception:
    sys.exit(0)   # bulletproof fail-open: never break a turn
PY
