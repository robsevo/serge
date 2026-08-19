#!/usr/bin/env bash
# Serge Stop hook — seven mechanical persistence checks, no LLM call ($0 per stop):
#
#  1. STALL: serge ends the turn on an announced but un-taken next action
#     ("let me check…", "I'll now …", "Checking the config…"). Nudge it to
#     actually take the step.
#  2. FALSE-DONE (added 2026-07-11): serge CLAIMS completed work ("I've fixed…",
#     "all done") but the entire turn since the user's last message made ZERO
#     tool calls — nothing was executed. Nudge it to do the work or correct
#     the claim. This closes the gap where the old DONE allow-list let any
#     "done" claim through unverified.
#  3. UNTESTED-DONE (added 2026-07-21, HARDENING_PLAN F.3): serge claims the
#     work is done AND code files were edited this turn, but NO test/verify
#     command ran after the edits and the message doesn't disclose "not yet
#     tested". Mechanical enforcement of the feature-flow doctrine
#     (BRAINSTORM→PLAN→BUILD→TEST→CONFIRM — skills/feature-flow): a feature is
#     done when built, TESTED and CONFIRMED, or honestly reported unverified.
#     Doc-only edits are exempt (see 3b); disclosure ("built, NOT yet tested") passes.
# 3b. UNREAD-DOC (added 2026-08-15): serge claims done AND wrote a document this
#     turn, but never Read it back. Check 3's doc exemption left documentation as
#     the only mutating write with nothing watching it — and prose is the one
#     artifact where being wrong costs nothing at write time. Disclosure passes;
#     content-level partner is doc-reality-gate.sh, pre-work is docs-directive.sh.
#  4. PARKED (added 2026-07-25): serge dispatches background agents/tasks and
#     ends the turn waiting on them ("I'll synthesize once they report back").
#     The user then has to prod it. Nudge it to collect the results in-turn.
#  5. PLAN-ONLY (added 2026-07-25): the turn ends on a list of forward-looking
#     steps with no code written. The stall check keys on an announcement VERB
#     and a bare numbered plan has none, so this walked straight through.
#     Menus of options and plan-mode turns are exempt.
#  6. OVER-ASK (added 2026-07-25): the turn ends asking permission to do the
#     very thing that was just ordered ("Fix the parser." → "Would you like me
#     to fix the parser?" / "Should I proceed?"). A full round-trip to arrive
#     back where we already were. Irreversible actions and genuine forks still
#     get to ask.
#  7. EMPTY-ANSWER (added 2026-07-25): the final message carries no content
#     ("[Tool results received]", "No response requested.").
#
# Checks 4-7 come from labelling flow breaks by the USER'S OWN REACTION: every
# stop in ~/.serge/projects/*/*.jsonl whose next human message was a prod
# ("continue", "do it", "wheres the rest", "??") — 28 of 519 stops, 5.4%.
#
# All seven are mechanical enforcement of the constitution's `### persistence`
# rule. A *block* makes serge take one more turn (work the user already wanted),
# so it spends only on intended work, never busy-loops cost.
#
# ── 2026-07-25 rewrite: four defects found by replaying every real stop point in
#    ~/.serge/projects/*/*.jsonl (622 stops) plus fixture tests against the
#    deployed hook. Each is fixed below and pinned by a case in
#    tests/test-continue-on-unfinished.sh:
#
#    D1 TRANSCRIPT RACE — the hook read the final text off the transcript FILE,
#       but the Stop hook fires ~250ms after the assistant row is emitted and the
#       file is not always flushed yet. A stale read leaves a tool_use row last →
#       `last_had_tool` → silent exit, no nudge. Nondeterministic: the same stall
#       is caught in one session and missed in the next. Confirmed live: session
#       36ebfb3f… row 84 ends "I will read them in parallel…", row 85 is
#       stop_hook_summary with hasOutput:false — yet replaying that exact
#       transcript through this hook DOES block. The harness already passes the
#       text in-band as `last_assistant_message` (hooks.ts: "so hooks can inspect
#       the final response without reading the transcript file") and the running
#       build emits it. We now prefer that field and use the transcript only as a
#       fallback / for the tool-call signals.
#
#    D2 ALLOW-LIST PRE-EMPTION — the "real completion" allow-list was substring-
#       matched over the last 400 chars and evaluated BEFORE the stall check, so
#       ANY message containing "here's the" / "summary:" / "done." / "let me know"
#       was permanently immune to the stall check. "Here's the fix: bump the
#       index. Let me verify that for you." stopped clean. Completion is now
#       judged on the message's CLOSING statement, and only vetoes the
#       backstop branch — never a stall that is itself the closing.
#
#    D3 TELEGRAPHIC ANNOUNCEMENTS — the announce pattern only knew first-person
#       modal forms ("let me X", "I'll X"). Real stalls routinely use bare
#       participles: "Checking the config now…", "On it — pulling up the logs.",
#       "Investigating the stream handler." All stopped clean. Now covered, with
#       a report-marker guard so past-tense findings that merely start with a
#       participle ("Running the suite gave 412 passes") still stop.
#
#    D4 HAND-BACK vs PARK — "I'll wait for your call" (legitimately yielding to
#       the user) and "I'll wait for the agent to report" (parking on our own
#       background job) were indistinguishable. The first must stop, the second
#       must continue. Split into HANDBACK (allow) and PARKED (block).
#
# Safety:
#   1. Off-switch:            SERGE_AUTOCONTINUE_DISABLE=1
#   2. Anti-stuck loop:       never re-nudge the SAME final text twice (if the
#                             nudge didn't change serge's output, let it stop).
#   3. Per-session hard cap:  SERGE_AUTOCONTINUE_CAP (default 60).
#   4. Never forces past a genuine question or a hand-back to the user, and
#      never fires when the final message made a tool call. FALSE-DONE
#      additionally skips pure Q&A turns (user's message ended with "?").
#
# Wired as a Stop hook in ~/.serge/settings.json (via stop-checks.sh stage 0).
set -uo pipefail

[ "${SERGE_AUTOCONTINUE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

SERGE_AUTOCONTINUE_CAP="${SERGE_AUTOCONTINUE_CAP:-60}" \
python3 - "$input" <<'PY'
import sys, json, os, re, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

# ── D1: the harness hands us the final assistant text in-band. Prefer it; the
#    transcript file may not be flushed yet when this hook runs. ──
harness_text = (d.get("last_assistant_message") or "").strip()
# Key PRESENT but empty ⇒ the harness saw a final assistant message with no text
# (thinking-only turn). Key ABSENT ⇒ no final message to judge, or a build that
# predates the hooks.ts change; fall back to the transcript in that case.
harness_has_key = "last_assistant_message" in d

tx = d.get("transcript_path") or ""
have_tx = bool(tx) and os.path.exists(tx)
if not harness_text and not have_tx:
    sys.exit(0)

# --- single pass over the transcript ---
# Track: the LAST assistant turn's text / tool use, the last REAL user message
# (human text, not tool_result rows, not isMeta injections), how many tool_use
# blocks appeared SINCE that user message, which CODE files were edited (F.3),
# and whether a test/verify command ran (F.3).
DOC_FILE = re.compile(r"\.(?:md|markdown|txt|rst|adoc)$", re.I)
VERIFY_CMD = re.compile(
    r"(?:\b(?:pytest|py\.test|tox|unittest)\b"
    r"|python3?\s+-m\s+(?:pytest|unittest)"
    r"|\b(?:bun|npm|yarn|pnpm)\s+(?:run\s+)?test\b"
    r"|\b(?:jest|vitest|mocha)\b|node\s+--test"
    r"|\bcargo\s+test\b|\bgo\s+test\b|\bmake\s+(?:test|check)\b"
    r"|\bmvn\s+test\b|\bgradle\s+test\b"
    r"|\btest[-_][\w.-]*\.(?:sh|mjs|py|ts)\b|[\w.-]*[-_]test\.(?:sh|mjs|py|ts)\b"
    r"|\bself-?test\b|--self-test"
    r"|\bplaytest\.mjs\b|\bgdtest\.sh\b|\bstream_check\.py\b|\brun-decisions\.mjs\b"
    r"|\bcurl\b|\bhttpie\b"
    r"|\bbash\s+\S*tests?/)",
    re.I,
)
# Commands that reach the DEPLOYED surface or a deployment control plane — as
# opposed to a build and a push, which both complete happily on this machine
# while production serves the old bundle.
LIVE_PROBE = re.compile(
    r"\b(?:curl|wget|http|https|xh)\b"
    r"|\bvercel\b|\bnetlify\b|\bfly\s+deploy\b|\bwrangler\s+(?:deploy|publish)\b"
    r"|\bgh\s+(?:workflow\s+run|run\s+(?:watch|view|list)|api)\b"
    r"|\bkubectl\s+rollout\b|\bdocker\s+push\b",
    re.I,
)
# What a FAILING verify run looks like across the runners this box uses. Kept
# conservative: a false "failed" only costs one extra turn of honesty, while a
# false "passed" is the hallucinated-completion bug this whole family exists for.
FAIL_SIGNAL = re.compile(
    r"\b[1-9]\d*\s+fail(?:ed|ing|ures?)?\b"      # "3 failed" — but never "0 failed"
    r"|\bexit(?:\s+code|ed\s+with)\s*[:=]?\s*[1-9]"
    r"|\berror\s+TS\d+"
    r"|\bnot\s+ok\b",
    re.I,
)
# Case-SENSITIVE on purpose. Under re.I a bare `FAILED` matches the "failed" in
# "0 failed" and marks a green suite red — measured on `bun test` output. Runners
# shout their failures in caps (pytest `FAILED tests/x.py`, `=== FAILURES ===`),
# while the zero-tally line is lowercase, so case is the discriminator.
FAIL_SIGNAL_CS = re.compile(
    r"\bFAILED\b|\bFAILURES\b|\bAssertionError\b|\bTraceback\b|\bPanic\b"
)
LOCALHOST = re.compile(r"localhost|127\.0\.0\.1|0\.0\.0\.0|::1", re.I
)
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
last_text, last_had_tool = "", False
user_text = ""
perm_mode = str(d.get("permission_mode") or d.get("permissionMode") or "")
tools_since_user = 0
code_edits = []          # non-doc file paths edited since the user's message
doc_edits = {}           # doc path -> "written" | "read" since the user's message (3b)
verify_ran = False       # a verify command ran AND its result looked passing
verify_failed = False    # a verify command ran and its result looked FAILING
pending_verify = set()   # tool_use_ids of verify commands awaiting their result
live_probed = False      # something touched the DEPLOYED surface, not just local (3d)
tool_names = {}          # tool name -> call count, for the silent-turn summary
if have_tx:
    try:
        with open(tx, encoding="utf-8") as fh:
            for line in fh:
                if '"assistant"' not in line and '"user"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                etype = e.get("type")
                m = e.get("message") or {}
                if etype == "user":
                    # Tool RESULTS arrive on user rows. Read the outcome of any
                    # verify command we flagged on the way past: check 3 used to
                    # set verify_ran on the INVOCATION, so a model could run the
                    # suite, watch it fail, claim "All done", and pass the gate.
                    # "Ran a test" is not the bar; "the test passed" is.
                    c0 = m.get("content")
                    if isinstance(c0, list):
                        for b in c0:
                            if not isinstance(b, dict) or b.get("type") != "tool_result":
                                continue
                            tid = b.get("tool_use_id")
                            if tid not in pending_verify:
                                continue
                            pending_verify.discard(tid)
                            body = b.get("content")
                            if isinstance(body, list):
                                body = " ".join(
                                    x.get("text", "") for x in body
                                    if isinstance(x, dict)
                                )
                            body = str(body or "")
                            if (b.get("is_error") or FAIL_SIGNAL.search(body)
                                    or FAIL_SIGNAL_CS.search(body)):
                                verify_failed = True
                            else:
                                verify_ran = True
                    if e.get("isMeta"):
                        continue
                    c = m.get("content")
                    human = ""
                    if isinstance(c, str):
                        human = c
                    elif isinstance(c, list):
                        human = "\n".join(
                            b.get("text", "") for b in c
                            if isinstance(b, dict) and b.get("type") == "text"
                        )
                    if human.strip():
                        user_text = human.strip()
                        tools_since_user = 0
                        code_edits = []
                        doc_edits = {}
                        verify_ran = False
                        verify_failed = False
                        pending_verify = set()
                        live_probed = False
                        tool_names = {}
                        # Plan mode legitimately ends the turn on a plan; the
                        # plan/over-ask checks must not fire there. Transcript
                        # user rows carry it as `permissionMode`.
                        if e.get("permissionMode"):
                            perm_mode = str(e.get("permissionMode"))
                    continue
                if etype != "assistant":
                    continue
                texts, had_tool = [], False
                for b in (m.get("content") or []):
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text" and b.get("text"):
                        texts.append(b["text"])
                    elif b.get("type") == "tool_use":
                        had_tool = True
                        name = b.get("name") or ""
                        binput = b.get("input") or {}
                        # Tallied for the deterministic silent-turn summary
                        # below. Counted per BLOCK (not per assistant turn like
                        # tools_since_user) so parallel calls in one turn show up.
                        if name:
                            tool_names[name] = tool_names.get(name, 0) + 1
                        if name in EDIT_TOOLS:
                            fp = str(binput.get("file_path") or binput.get("notebook_path") or "")
                            if fp and not DOC_FILE.search(fp):
                                code_edits.append(fp)
                            elif fp:
                                # 3b: a doc write RE-ARMS the unread state. Reading
                                # it before the write proves nothing about what the
                                # write produced.
                                doc_edits[fp] = "written"
                        elif name == "Read":
                            fp = str(binput.get("file_path") or "")
                            if fp in doc_edits:
                                doc_edits[fp] = "read"
                        elif name == "Bash":
                            _cmd = str(binput.get("command") or "")
                            if VERIFY_CMD.search(_cmd):
                                # Provisional: confirmed only when its RESULT
                                # comes back clean (see the user-row handler).
                                _tid = b.get("id")
                                if _tid:
                                    pending_verify.add(_tid)
                                else:
                                    verify_ran = True
                            # 3d: did anything actually touch the DEPLOYED surface?
                            # A build and a push both happen on this machine; only
                            # these reach the thing users load.
                            if LIVE_PROBE.search(_cmd) and not LOCALHOST.search(_cmd):
                                live_probed = True
                        elif name == "WebFetch":
                            live_probed = True
                if had_tool:
                    tools_since_user += 1
                last_text = "\n".join(texts).strip()
                last_had_tool = had_tool
    except Exception:
        if not harness_text:
            sys.exit(0)

silent_turn = False
if harness_text:
    # In-band text wins. The turn is ending, so by definition the final message
    # has no pending tool call — the stale-transcript `last_had_tool` veto (D1)
    # does not apply on this path.
    final_text = harness_text
elif harness_has_key:
    # ── D5 SILENT TURN — the harness says the final assistant message exists and
    #    its text is EMPTY. The model burned reasoning tokens and emitted no text
    #    block at all (observed live: 7 consecutive
    #    turns, up to 1409 output tokens each, stop_reason=end_turn, zero text —
    #    the user typed "continue? why did you stop", "give me an answer", "hey
    #    serge whats up" and got silence every time). Every one of those stops
    #    fell through the `not last_text` exit below with preventedContinuation:
    #    false. An empty final message is not "nothing to check" — it is the
    #    loudest possible failure, and Check 0 nudges it.
    #
    #    Hash on the USER's message, not the (constant) empty text, so each new
    #    prod re-arms exactly one nudge; hashing "" would let the anti-identical
    #    guard silence every silent turn after the first.
    silent_turn = True
    final_text = "\x00silent-turn\x00" + user_text
elif last_had_tool or not last_text:
    # Fallback path only: a tool call in the final row means serge is mid-work.
    sys.exit(0)
else:
    final_text = last_text

if not final_text:
    sys.exit(0)

# ── Never fight the user's Esc. If the turn ended because the user interrupted
#    it, every check below would be arguing for work they just cancelled — the
#    same invariant query.ts enforces for StopFailure continuations ("Never
#    resume a turn the user stopped"). Observed in the corpus: two "No response
#    requested." finals directly after `[Request interrupted by user]`. ──
if re.match(r"^\s*\[Request interrupted by user", user_text, re.I):
    sys.exit(0)

# ── segmentation ──────────────────────────────────────────────────────────
# Decisions anchor on the message's CLOSING statement (D2): what serge said LAST
# is what it is doing next. A completion phrase earlier in the message no longer
# grants immunity to the stall check.
FENCE = re.compile(r"```.*?```", re.S)
body = FENCE.sub(" ", final_text).strip() or final_text
tail = body[-400:]

def closing_of(t):
    """Last prose statement → (last sentence, last two sentences, is_bullet).

    Skips blank lines, horizontal rules, stray fences and table rows. Returns the
    LAST sentence: "Let me recap what changed: … All set." closes on the sign-off,
    not on the recap. A short trailing fragment that carries no signal ("Now.")
    falls through to the whole-tail backstop. The two-sentence window is what
    hand-backs are judged on — "Would you like me to commit? If so, I'll ignore
    the temp files." yields to the user across a sentence boundary.
    """
    for raw in reversed(t.splitlines()):
        line = raw.strip()
        if not line:
            continue
        if re.fullmatch(r"(?:[-*_=]{3,}|`{3,}.*|\||\|.*\|)", line):
            continue
        # A trailing bare link / URL / path is a citation, not a statement —
        # keep walking back to the prose that introduced it.
        if re.fullmatch(r"(?:[-*+>]\s*)?[*_`\[]*(?:\[[^\]]*\]\([^)]*\)|https?://\S+|`[^`]+`|/\S+)[*_`\].,:;]*",
                        line):
            continue
        bullet = bool(re.match(r"^(?:[-*+>]|\d+[.)])\s+", line))
        line = re.sub(r"^(?:[-*+>]|\d+[.)])\s+", "", line)          # list bullet
        line = re.sub(r"^#{1,6}\s+", "", line)                       # heading
        line = line.strip("*_` ")
        if not line:
            continue
        parts = [p.strip() for p in re.split(r"(?<=[.!?…])\s+", line) if p.strip()]
        if not parts:
            return line, line, bullet
        return parts[-1], " ".join(parts[-2:]), bullet
    return "", "", False

closing, closing2, closing_is_bullet = closing_of(body)
low_closing = closing.lower()

# --- shared loop guards: anti-identical-stall + per-session cap ---
sid = str(d.get("session_id") or "nosid")
base = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                    "serge-autocontinue-" + hashlib.sha1(sid.encode()).hexdigest()[:12])
cntf, hashf = base + ".cnt", base + ".last"
cur = hashlib.sha1(final_text.encode("utf-8", "ignore")).hexdigest()[:16]

def read(p, dflt=""):
    try:
        return open(p).read().strip()
    except Exception:
        return dflt

COOLED = {}   # set by silent_summary() when the stop looks router-exhausted


def arm_one_retry():
    # ONE automatic retry after a cooled-router stop ($0 — writes a file).
    #
    # Reuses the EXISTING, proven path rather than adding a retry loop:
    # ~/.local/bin/serge-resume already watches for this sentinel, waits, and
    # resumes the session once. That wrapper has its own freshness check and
    # MAX_RETRIES cap, so this cannot become the 240s/7-request storm that was
    # deliberately removed — see the "429 that retried for four minutes".
    #
    # Retrying IMMEDIATELY would be pointless: the router returned "try again in
    # 900 seconds" precisely because every deployment is cooled. But the routers
    # per-deployment `cooldown_time` is 60s (litellm.yaml), which beats the
    # router default, so capacity typically returns in ~a minute. The sentinel
    # therefore carries a suggested delay instead of relying on the wrappers
    # 15s default, which is shorter than the cooldown it is waiting out.
    #
    # ARMED AT MOST ONCE PER EPISODE. The marker records the error-log mtime we
    # armed for, so a fresh outage re-arms but the same one never does twice —
    # "just once to see", not a loop.
    if not COOLED.get("yes"):
        return False
    if os.environ.get("SERGE_AUTORETRY_COOLED", "1") == "0":
        return False
    try:
        sentinel = os.path.expanduser(
            os.environ.get("SERGE_STOP_FAILURE_SENTINEL")
            or "~/.serge/stop-failure.sentinel")
        marker = sentinel + ".armed"
        stamp = str(COOLED.get("mtime", 0))
        if read(marker) == stamp:
            return False          # already armed for THIS outage
        delay = os.environ.get("SERGE_COOLED_RETRY_DELAY", "75")
        # Superset of the legacy format: on-stop-failure.sh writes the bare
        # session id "for external watchers", so keep it on line 1 and add the
        # key=value lines after. serge-resume anchors its parse to ^delay=, so
        # both shapes stay readable and neither reader has to change.
        with open(sentinel, "w") as fh:
            fh.write("%s\nreason=router_cooled\ndelay=%s\n"
                     % (str(d.get("session_id") or ""), delay))
        with open(marker, "w") as fh:
            fh.write(stamp)
        return True
    except Exception:
        return False              # fail-open: never break the stop path


def silent_summary():
    # DETERMINISTIC close-out for a turn that ended with no text ($0, no LLM).
    #
    # WHY THIS EXISTS: Check 0 below nudges the model to describe its own work,
    # which is strictly better prose — but producing it REQUIRES a model call.
    # The case users actually hit is the free pool being drained (429 "No
    # deployments available"), where the nudge cannot be answered: it goes out,
    # nothing comes back, the anti-identical guard sees the same empty text and
    # gives up, and the turn ends in silence. The explanation needed the router
    # that was out. So when the nudge path gives up, say what happened from
    # LOCAL evidence only — the transcript we already parsed.
    #
    # Deliberately mechanical and labelled as such. It is not a substitute for
    # serge reporting its work; it exists so a blank screen becomes a receipt.
    bits = []
    if tool_names:
        top = sorted(tool_names.items(), key=lambda kv: (-kv[1], kv[0]))[:4]
        bits.append("%d tool call(s) — %s" % (
            sum(tool_names.values()),
            ", ".join("%s x%d" % (n, c) for n, c in top)))
    if code_edits:
        uniq = list(dict.fromkeys(code_edits))
        shown = ", ".join(os.path.basename(p) for p in uniq[:4])
        more = "" if len(uniq) <= 4 else " (+%d more)" % (len(uniq) - 4)
        bits.append("%d file(s) changed: %s%s" % (len(uniq), shown, more))
        bits.append("tests/verify ran" if verify_ran else "NO test or verify command ran")
    if not bits:
        bits.append("no tool calls recorded since your last message")

    # Why it stopped, when local evidence can say. A very recent router error is
    # the common cause and is the difference between "serge ignored me" and
    # "the free pool is cooling down" — read only the tail, never the whole log.
    cause = ""
    try:
        import time
        errlog = os.path.expanduser(
            os.environ.get("SERGE_QUERY_ERRORS_LOG") or "~/.serge/serge-query-errors.log")
        if os.path.exists(errlog) and (time.time() - os.path.getmtime(errlog)) < 180:
            with open(errlog, "rb") as fh:
                size = fh.seek(0, 2)
                fh.seek(max(0, size - 4096))
                tail = fh.read().decode("utf-8", "ignore")
            if "No deployments available" in tail:
                # Flagged, not acted on here: silent_summary() is evaluated when
                # block() is CALLED, which includes the pass where the model
                # nudge still fires. Arming a retry must happen only on the
                # actual give-up, so the side effect lives in give_up().
                COOLED["yes"] = True
                COOLED["mtime"] = int(os.path.getmtime(errlog))
                cause = ("  Likely cause: every model seat is cooling down "
                         "(router returned 429 within the last 3 minutes). "
                         "This is capacity, not a refusal.")
            elif "status=4" in tail or "status=5" in tail:
                cause = "  A router/API error was logged in the last 3 minutes; see ~/.serge/serge-query-errors.log."
    except Exception:
        pass

    return ("Serge ended the turn without writing a reply. Mechanical summary of what the "
            "turn did (generated locally from the transcript, no model call — serge did NOT "
            "describe its own work):\n  - " + "\n  - ".join(bits) +
            ("\n" + cause if cause else "") +
            "\n  Treat this as a receipt, not a report: nothing above was reviewed by serge.")


def block(reason, fallback=None):
    # Same final text as last time → the nudge didn't move serge; let it stop.
    # `fallback` (Check 0 only) is the deterministic close-out: the nudge has
    # already been tried and did not produce text, so this is the last chance to
    # tell the user anything at all. Emitted on BOTH give-up paths.
    def give_up():
        if fallback:
            msg = fallback
            if arm_one_retry():
                msg += ("\n  Auto-retry ARMED: one resume will run once the cooldown "
                        "passes (serge-resume picks this up after serge exits). "
                        "Disable with SERGE_AUTORETRY_COOLED=0.")
            print(json.dumps({"systemMessage": msg}))
        sys.exit(0)
    if read(hashf) == cur:
        give_up()
    cap = int(os.environ.get("SERGE_AUTOCONTINUE_CAP", "60"))
    try:
        n = int(read(cntf, "0") or "0")
    except Exception:
        n = 0
    if n >= cap:
        give_up()
    try:
        open(hashf, "w").write(cur)
        open(cntf, "w").write(str(n + 1))
    except Exception:
        pass
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)

# --- Check 0 (D5): SILENT TURN — no text block emitted at all ---
# Strictly worse than Check 7's "[Tool results received]": there the user got a
# useless sentence, here they got a blank screen and a spinner that stopped.
# Runs first because every other check reasons about wording, and there is none.
if silent_turn:
    block(
        "Your last turn ended without emitting any text — the user saw a blank response. "
        "Whatever you worked out stayed in your reasoning, which is not shown to them, so from "
        "where they sit nothing happened at all. Answer now, in plain visible text: what you "
        "found, what you changed, and what is left. If the work is genuinely incomplete, say "
        "what is blocking it. Do not open with an apology and do not re-run the investigation "
        "you already did — just report it.",
        fallback=silent_summary(),
    )

# --- Check 7: CONTENT-FREE FINAL MESSAGE ---
# "[Tool results received]" / "No response requested." — the turn ended without
# an answer in it. Nothing downstream can salvage that; the user just retypes.
EMPTY_ANSWER = re.compile(
    r"^\W*(?:\[?\s*tool\s+results?\s+received\s*\]?"
    r"|no\s+response\s+(?:requested|needed|required)"
    r"|acknowledged|understood|noted|ok(?:ay)?|got\s+it|continuing|proceeding)"
    r"[\s.!\]]*$",
    re.IGNORECASE,
)
# …unless a terse literal reply is exactly what was asked for ("Reply with
# exactly: OK" → "OK" is a correct answer, not an empty one).
LITERAL_REPLY_REQUEST = re.compile(
    r"\b(?:reply|respond|answer)\s+with\b|\bsay\s+exactly\b|\bjust\s+say\b|"
    r"\b(?:one|single)\s+word\b|\boutput\s+only\b|\bprint\s+only\b|\bexactly:\s*\S",
    re.IGNORECASE,
)
if (len(body) <= 60 and EMPTY_ANSWER.match(body.strip())
        and not LITERAL_REPLY_REQUEST.search(user_text)):
    block(
        "Your final message carried no content — it acknowledges the turn instead of answering "
        "it. Nothing you learned or did is in there, so the user has nothing to act on. Either "
        "continue the work, or state in one or two lines what you found, what you changed, and "
        "what is left. Never end a turn on an acknowledgement."
    )

# ── shared shape tests for checks 5 and 6 ────────────────────────────────
# Did the user ISSUE AN ORDER, or ask for thinking? "fix the parser" is an order;
# "what's your plan / how would you / suggest an approach" is not, and ending on a
# plan or a question is the correct answer to those.
IMPERATIVE_USER = re.compile(
    r"^\s*(?:ok(?:ay)?|so|now|then|and|but|also|please|hey|yo|alright)?[\s,.!—-]*"
    r"(?:please\s+|go\s+ahead\s+and\s+|just\s+|can\s+you\s+|could\s+you\s+|i\s+want\s+you\s+to\s+|"
    r"i\s+need\s+you\s+to\s+|let'?s\s+)?"
    r"(?:add|fix|make|build|implement|update|remove|delete|refactor|write|create|change|"
    r"set\s+up|setup|wire|port|migrate|clean|improve|optimi[sz]e|run|install|configure|"
    r"hook|integrate|finish|continue|complete|do|apply|patch|rename|move|split|merge|"
    r"enable|disable|verify|test|check|investigate|debug|diagnose|research|find|look)\b",
    re.IGNORECASE,
)
PLAN_REQUEST = re.compile(
    r"\b(?:what(?:'s| is)\s+(?:your|the)\s+plan|how\s+would\s+you|what\s+would\s+you|"
    r"suggest|propose|recommend|advice|options?\b|outline|draft\s+a\s+plan|"
    r"plan\s+(?:it|this|that)\s+out|just\s+(?:the\s+)?plan|don'?t\s+(?:code|implement|write|build)|"
    r"brainstorm|design\s+(?:me\s+)?a|what\s+do\s+you\s+think|thoughts\?|explain|walk\s+me\s+through|"
    r"should\s+(?:i|we)\b|which\s+(?:one|approach|option))",
    re.IGNORECASE,
)
# A stated problem or requirement is an order too. "the problem is X, it needs
# to be Y" carries the same authorization as "fix X" — answering it with "shall
# I proceed?" is the same round-trip. Observed: a captcha bug report answered
# with a 2-step plan and "Should I proceed?", user replied "go".
NEED_USER = re.compile(
    r"\b(?:the problem is|problem:|the issue is|it needs to|needs? to be|we need|"
    r"(?:doesn'?t|does not|isn'?t|is not|won'?t|will not|can'?t|cannot)\s+work|"
    r"is\s+broken|are\s+broken|not\s+working|still\s+(?:broken|failing|not\s+working)|"
    r"should\s+(?:be|have|show|return|use|only)|make\s+sure|has\s+to\s+\w+)\b",
    re.IGNORECASE,
)
IN_PLAN_MODE = perm_mode.lower().startswith("plan")

CLAIM = re.compile(
    r"\b(?:i(?:'ve| have)(?:\s+(?:now|just|already|successfully))?|i(?:\s+(?:then|now|just|also))?)\s+"
    r"(?:fixed|implemented|created|updated|added|removed|refactored|installed|"
    r"deployed|wrote|built|applied|patched|configured|deleted|renamed|rebuilt|"
    r"committed|pushed|edited|corrected)\b"
    r"|\ball done\b|\btask (?:is )?complete\b"
    r"|\bthe\s+(?:fix|change|work|implementation)\s+is\s+(?:complete|done|in place)\b"
    r"|\bis\s+complete\s+and\s+verified\b|\bfix\s+is\s+(?:complete|verified)\b"
    r"|\beverything (?:is|'s) (?:now )?(?:fixed|working|done|in place)\b",
    re.IGNORECASE,
)
cm = CLAIM.search(final_text.lower())
user_is_order = (bool(IMPERATIVE_USER.search(user_text)) or bool(NEED_USER.search(user_text))) \
                and not PLAN_REQUEST.search(user_text)

# --- Check 6: OVER-ASK — offering to do the very thing that was just ordered.
# "Fix the parser." → "Would you like me to fix the parser?" is the most
# infuriating flow break there is: a whole round-trip to say yes to your own
# request. Runs BEFORE the question guard, because the pathology IS a question.
# Deliberately narrow — a wrong block here forces action where asking was right:
#   · only when the user gave a direct order (not a plan/advice request)
#   · only when NOTHING was built this turn and no completion was claimed
#   · never for irreversible or outward-facing actions — those must be confirmed
#   · never for a genuine either/or choice, and never in plan mode.
OFFER = re.compile(
    r"\b(?:would you like me to|want me to|shall i|should i|do you want me to|"
    r"would you like for me to|ready for me to)\s+([^?]{0,90})\?",
    re.IGNORECASE,
)
IRREVERSIBLE = re.compile(
    r"\b(?:deploy|push|publish|release|merge|commit|delete|drop|wipe|purge|reset|revert|"
    r"force|overwrite|send|email|post|tweet|charge|pay|purchase|uninstall|rm\b|prod\b|"
    r"production|live\b|migrate)\b",
    re.IGNORECASE,
)
# A genuine fork ("two ways to do this… want me to X?") is a real question, and
# it is usually stated in the sentence BEFORE the offer — check the whole tail.
FORK = re.compile(
    r"\b(?:\bor\b|either\b|two (?:ways|options|approaches|choices)|"
    r"(?:option|approach|choice)\s*(?:a|b|1|2|one|two)\b|which\s+(?:one|of)|"
    r"there are (?:two|three|several|a few))",
    re.IGNORECASE,
)
_STOP = {"the","a","an","it","this","that","now","then","and","or","to","for","with","you",
         "me","my","your","i","is","are","be","do","go","all","them","these","those","in",
         "on","of","at","as","so","if","up","out","from","into","its","their","there","here",
         "what","when","also","just","first","next","one","two","some","any","not","no"}
def _content(s):
    return {w for w in re.findall(r"[a-z][a-z0-9_.-]{2,}", s.lower()) if w not in _STOP}
def _head_verb(s):
    m = re.match(r"\s*(?:please\s+|go\s+ahead\s+and\s+|just\s+)?([a-z]+)", s.lower())
    return m.group(1) if m else ""

# "Should I proceed?" needs no matching test — "proceed" IS the whole task by
# definition, so it is always an over-ask when an order is outstanding and
# nothing was built. Judged on its own sentence so "proceed with the deploy?"
# still counts as irreversible and gets to ask.
GENERIC_PROCEED = re.compile(
    r"[^.!?]*\b(?:(?:should|shall|may|can|want me to|would you like me to|ready for me to)\s+i?\s*"
    r"(?:proceed|start|begin|go\s+ahead|continue|implement|kick\s+off)"
    r"|ready to (?:proceed|start|begin|implement)"
    r"|do you have any (?:concerns|objections)"
    r"|(?:sound|look)s? good\?)[^.!?]*[.!?]?",
    re.IGNORECASE,
)
gp = GENERIC_PROCEED.search(closing2)
if (gp and user_is_order and not cm and not code_edits and not IN_PLAN_MODE
        and not IRREVERSIBLE.search(gp.group(0))):
    asked = re.sub(r"\s+", " ", gp.group(0)).strip()[:80]
    block(
        f'You stopped to ask permission to begin ("{asked}"). The instruction you were given IS '
        "the go-ahead — asking for it again spends a full round-trip to arrive back where you "
        "already were. Begin now. Ask only when the next action is irreversible or "
        "outward-facing, or when a choice genuinely needs the user's judgement."
    )

om = OFFER.search(closing2)
# The offer must be the SAME work the user ordered. Serge legitimately offers
# unrelated extras ("want me to also check the leads page?") — that is a real
# question, not an over-ask. Require a shared content word (≥4 chars) or the
# same head verb between the order and the offer.
offer_matches_order = False
if om:
    ov, uv = _head_verb(om.group(1)), _head_verb(re.sub(
        r"^\s*(?:ok(?:ay)?|so|now|then|please|hey)?[\s,.!—-]*", "", user_text))
    shared = {w for w in _content(om.group(1)) & _content(user_text) if len(w) >= 4}
    offer_matches_order = bool(shared) or (bool(ov) and ov == uv)

if (om and offer_matches_order and user_is_order and not cm and not code_edits
        and not IN_PLAN_MODE
        and not IRREVERSIBLE.search(om.group(1))
        and not FORK.search(tail)):
    offered = re.sub(r"\s+", " ", om.group(0)).strip()[:80]
    block(
        f'You ended by asking permission to do the thing you were already told to do ("{offered}"). '
        "The request WAS the authorization — asking again costs the user a round-trip and gets the "
        "same answer. Do it now. Reserve questions for choices only the user can make (a genuine "
        "fork between options, missing information you cannot obtain, or an irreversible / "
        "outward-facing action) — this is none of those."
    )

# --- Guard A: a genuine question to the user → never force past it. ---
if body.rstrip().endswith("?") or closing.rstrip().endswith("?"):
    sys.exit(0)

# --- Guard B (D4): HAND-BACK — serge is yielding to the USER, not stalling.
# Judged on the last two sentences (a hand-back often spans a boundary:
# "Would you like me to commit? If so, I'll ignore the temp files.").
# Note what is NOT here: a bare "I'll wait…". Waiting is only a hand-back when
# the thing being waited on is the user — "I'll wait for the agent to report"
# is a park, and falls through to PARKED below.
WAIT_ON_USER = re.compile(
    # The user must be the OBJECT of the wait, not merely nearby: "waiting on the
    # researcher — I'll let you know" is a park that happens to contain "you".
    r"\b(?:wait(?:ing)?|await(?:ing)?|hold(?:ing)?(?:\s+off)?|stand(?:ing)?\s+by|pending)\b"
    r"[^.?!]{0,15}?\b(?:you|your|user'?s)\b"
    # Idle-at-the-prompt phrasing: the thing being awaited IS the user's next
    # instruction, even though the word "you" never appears.
    r"|\b(?:awaiting|await|ready for)\s+(?:the\s+|a\s+|your\s+)?"
    r"(?:task|tasks|instruction|instructions|direction|directions|orders|request|"
    r"prompt|input|next steps?|assignment)\b"
    r"|\bready when you are\b|\bno confirmation needed\b",
    re.IGNORECASE,
)
# Only a request for DIRECTION yields the turn. A courtesy aside ("let me know
# if you want more") must not shield a concrete closing action — that is exactly
# the D2 pre-emption bug, one layer up. So: "let me know WHAT/WHICH/HOW" yields,
# "let me know IF" does not.
HANDBACK = re.compile(
    r"\b(?:let me know\s+(?:what|which|how|where|when|whether|if you'?d like me)\b"
    r"|(?:need|needs)\s+(?:your|you to)\b|i need (?:you|your)\b"
    r"|up to you\b|your call\b|your decision\b|whichever you\b|no further input\b"
    r"|would you like\b|want me to\b|do you want\b|shall i\b|should i\b|ready for me to\b"
    r"|say the word\b|tell me (?:what|which|how)\b|confirm and i'?ll\b"
    r"|(?:i'?ll|i will)\s+(?:stop here|leave (?:that|it|this)|defer)\b"
    r"|over to you\b|awaiting your\b|pending your\b|your (?:approval|go-ahead|input)\b"
    r"|if so,|if you'?d (?:like|prefer)|if you want me to|if that works|once you confirm)",
    re.IGNORECASE,
)
# Handing the user something they can act on themselves ("you can monitor it
# here: <link>") is a hand-back, not a park, even when a job is still running.
USER_ACTIONABLE = re.compile(
    r"\byou (?:can|could|may|might|should|will|now)\b|\byou'?ll\b|\bfeel free\b",
    re.IGNORECASE,
)

# --- Guard C (D4): PARKED — serge dispatched background work and is idling on
# it. Not a hand-back: the user is not the blocker, our own job is.
PARKED = re.compile(
    # "Waiting on verifier results." / "Await agent results." / "I will wait for
    # the agent to report" — the wait must open a sentence or hang off a
    # first-person subject, so "the tests are waiting on a lock" stays a report.
    r"(?:^|[.!?…]\s+|\b(?:i'?ll|i will|i am|i'?m|we'?ll|we'?re|still|currently|now|then)\s+(?:just\s+)?)"
    r"(?:wait(?:ing)?|await(?:ing)?|stand(?:ing)?\s+by|hold(?:ing)?\s+off)\b"
    r"|\b(?:i'?ll|i will|then i'?ll)\b[^.?!]{0,60}"
    r"\b(?:let you know|update you|report back|share|synthesi[sz]e|summari[sz]e|"
    r"confirm|compile|assemble|integrate|determine)\b[^.?!]{0,80}"
    r"\b(?:once|when|as soon as|after|the moment)\b"
    r"|\bonce\b[^.?!]{0,60}\b(?:they|it|the agent|the agents|the task|the tasks|these)\b"
    r"[^.?!]{0,40}\b(?:done|complete[ds]?|finish(?:es|ed)?|report[s]?|return[s]?|land[s]?|come back)\b"
    r"|\bresults? (?:will|should) (?:arrive|come|land|be back)\b"
    r"|\bresults? will arrive\b|\bwill arrive as notifications?\b"
    r"|\bis (?:on it|running)\b[^.?!]{0,80}\bresults?\b",
    re.IGNORECASE,
)

# Companion to PARKED, used ONLY together with background_tasks_running > 0 (see
# the D6 guard before Check 4). PARKED is tuned to catch a park from wording alone,
# so it is deliberately strict; these phrasings are the ones that describe waiting
# WITHOUT tripping it — "the agents are still running", "have not yet returned",
# "upon their completion". On their own they are far too loose to gate a nudge on
# (any status report says "still running"), which is exactly why they live here
# instead: the harness has already confirmed work is in flight, so the only
# question left is whether this sentence is about that work.
BG_CONTINGENT = re.compile(
    r"\b(?:agents?|tasks?|jobs?|subagents?|workers?)\b[^.?!]{0,60}"
    r"\b(?:are|is|still)\b[^.?!]{0,30}\brunning\b"
    r"|\bhave\s+not\s+(?:yet\s+)?(?:returned|finished|completed|reported)\b"
    r"|\bhas\s+not\s+(?:yet\s+)?(?:returned|finished|completed|reported)\b"
    r"|\bupon\s+(?:their|its|the)\s+completion\b"
    r"|\b(?:once|when|as soon as|after)\b[^.?!]{0,40}"
    r"\b(?:they|it|these|those|the agents?|the tasks?)\b[^.?!]{0,30}"
    r"\b(?:finish|finishes|finished|complete[ds]?|land[s]?|return[s]?|are (?:done|back)|is (?:done|back))\b"
    r"|\bstill\s+(?:running|in\s+flight|in\s+progress|pending|working)\b",
    re.IGNORECASE,
)

# --- Check 2: FALSE-DONE — completion claim with zero tool calls this turn ---
# Only first-person past-action claims over MUTATION verbs (not "reviewed"/
# "analyzed", which are legitimately tool-free when answering from context),
# plus explicit sign-offs. Skipped for pure Q&A turns (user asked a question).
# (CLAIM / cm are defined above — check 6 needs them before the question guard.)
user_is_question = user_text.rstrip().endswith("?")
if cm and tools_since_user == 0 and have_tx and not user_is_question:
    snippet = re.sub(r"\s+", " ", cm.group(0)).strip()[:90]
    block(
        f'Your message claims completed work ("{snippet}…"), but this entire turn made ZERO '
        "tool calls — nothing was actually executed or verified. If the work truly happened "
        "in an earlier turn, restate that explicitly with concrete evidence (file path, command "
        "output). Otherwise perform the work NOW with tools before ending your turn — never "
        "report something as done that you did not do."
    )

# --- Check 3 (F.3): UNTESTED-DONE — done-claim over code edits with no test/
# verify run and no honest disclosure. Disclosure ("built, NOT yet tested") is
# a legitimate exit per the feature-flow doctrine — honesty beats theater.
DISCLOSE = re.compile(
    r"(?:\b(?:not|n['’]t|never)\s+(?:yet\s+)?(?:been\s+)?(?:tested|verified|run|confirmed|validated)\b"
    r"|\bunverified\b|\buntested\b|\bnot\s+yet\s+(?:tested|verified|run|confirmed)\b"
    r"|\bneeds?\s+(?:testing|verification|validation)\b"
    r"|\bhaven['’]?t\s+(?:run|tested|verified)\b)",
    re.IGNORECASE,
)
# 3a: the verify command RAN and came back FAILING, and the turn still claims
# done. This is the "deterministic checker" bar: the task is done when the suite
# exits clean, not when the model says the code is fixed. Ranked before the
# not-verified case below because it is strictly worse — the evidence of failure
# was on screen and got reported as success anyway.
if (cm and verify_failed and not user_is_question
        and not DISCLOSE.search(final_text)):
    block(
        "Feature-flow gate: a test/verification command ran this turn and its output shows "
        "FAILURES, but your final message claims the work is done. The checker already "
        "answered — it said no. Do not re-describe the change; fix it until the command exits "
        "clean, then report the passing output. If you cannot make it pass here, say plainly "
        "that it FAILS, quote the failing output, and name what remains — a failing suite "
        "reported as success is the single most expensive thing you can hand back."
    )

if (cm and code_edits and not verify_ran and not user_is_question
        and not DISCLOSE.search(final_text)):
    files = ", ".join(sorted({os.path.basename(p) for p in code_edits})[:4])
    more = "" if len(set(code_edits)) <= 4 else f" (+{len(set(code_edits)) - 4} more)"
    block(
        f"Feature-flow gate: this turn edited code ({files}{more}) and your final message "
        "claims the work is done, but NO test or verification command ran after those edits. "
        "A feature is BUILD → TEST → CONFIRM, not just build. Before ending the turn, either "
        "(a) run the relevant tests / drive the real surface NOW and report what you actually "
        "observed, or (b) if you genuinely cannot verify here, state plainly that the work is "
        "built but NOT yet tested and exactly what remains unverified. Never end on an "
        "unverified done-claim."
    )

# --- Check 3b: UNREAD-DOC — done-claim over a document that was written and
# never read back.
#
# WHY THIS IS SEPARATE FROM CHECK 3: DOC_FILE (above) strips .md/.txt/.rst/.adoc
# out of `code_edits`, so check 3 cannot fire on a documentation turn even in
# principle. That exemption was right — "run the tests" is meaningless for a
# README — but it left docs as the ONLY mutating write in this workspace with
# nothing waiting for it, and a document is precisely the artifact where being
# wrong costs nothing at write time. Measured (user report, 2026-08-15): a README
# rewrite came back thin, was declared done, and had to be asked for twice.
#
# The bar here is the weakest honest one that is still deterministic: you looked
# at what you produced. Reading the file back is not proof the prose is good, but
# writing a document and never once looking at the result is proof that nobody
# checked. Same disclosure exit as check 3 — saying "written, not reviewed" is a
# legitimate stop, because honesty beats theater.
#
# The content-level partner is doc-reality-gate.sh (PostToolUse), which checks
# the commands and paths at write time; the pre-work partner is docs-directive.sh.
unread_docs = [p for p, st in doc_edits.items() if st == "written"]
if (cm and unread_docs and not verify_ran and not user_is_question
        and not DISCLOSE.search(final_text)):
    files = ", ".join(sorted({os.path.basename(p) for p in unread_docs})[:4])
    more = "" if len(unread_docs) <= 4 else f" (+{len(unread_docs) - 4} more)"
    block(
        f"Doc gate: this turn wrote documentation ({files}{more}) and your final message claims "
        "the work is done, but you never read back what you wrote. A document is the one "
        "artifact where nothing fails when it is wrong — a stale command or a dead path just "
        "sits there looking correct — so the only check is you actually looking at it. Before "
        "ending the turn, either (a) Read each file you wrote, end to end, as the reader will, "
        "then report what you CHECKED (which commands you ran, which paths you confirmed) and "
        "what you did not, or (b) if you genuinely cannot verify here, say plainly which claims "
        "are unverified. Never end on an unverified done-claim."
    )

# --- Check 3c: FABRICATED VERIFICATION — the turn CLAIMS it checked an external
# system, and made no tool call that could have touched one.
#
# Measured (user report, 2026-08-16). Asked why example-web's events tab was empty,
# serge produced a section headed "Verification Steps Taken" containing
# "Checked the ESPN API Directly" and "verified by the data.events array being
# empty" — having issued one grep and four Reads, and zero network calls. It had
# read the FUNCTION that calls ESPN and narrated what that code would return as
# something it had observed. Its conclusion ("ESPN returns no events") was
# falsified by a single curl: 11 MLS events for the date in question.
#
# Checks 2/3/3b could not catch it. Check 2 needs ZERO tool calls (there were
# five), check 3 needs code edits, 3b needs doc writes. A pure ANALYSIS turn
# that fabricates verification was completely ungated — and analysis turns are
# exactly where guessing is cheapest, because no artifact exists to contradict
# it. Reading the code path is not running it.
#
# Narrow on purpose, three conditions:
#   1. a verification VERB in the first person ("I verified", "I checked",
#      "Verification Steps"), not the passive "the API returns X" of ordinary
#      code description;
#   2. an EXTERNAL subject — api/endpoint/url/http/request/response/curl —
#      because a claim about a local file IS verifiable with Read;
#   3. NO tool this turn that can reach one (Bash, WebFetch, WebSearch, MCP).
# Disclosure passes, same doctrine as 3/3b: "based on reading the code, not
# verified against the live API" is an honest, legitimate stop.
# Tools that can actually touch something outside this process. MCP servers count
# (a `mcp__*` tool may well be the thing that queried the live system).
PROBE_TOOLS = ("Bash", "BashOutput", "WebFetch", "WebSearch")
probed = any(t in tool_names for t in PROBE_TOOLS) or any(
    t.startswith("mcp__") for t in tool_names
)

VERIFY_CLAIM = re.compile(
    r"\bverification\s+steps\b"
    r"|\bsteps?\s+taken\b"
    r"|\b(?:i|we)\s+(?:have\s+)?(?:verified|confirmed|tested|checked|queried|hit|called|probed)\b"
    r"|\bchecked\s+the\s+\w+\s+(?:api|endpoint|directly)\b"
    r"|\b(?:verified|confirmed)\s+(?:by|that|against|via|in)\b",
    re.IGNORECASE,
)
EXTERNAL_SUBJECT = re.compile(
    r"\bapi\b|\bendpoint\b|\bhttps?://|\burl\b|\bcurl\b|\brequest(?:ed|s)?\b"
    r"|\bresponse\b|\bscoreboard\b|\bserver\b|\bupstream\b|\bfetch(?:ed|es)?\b",
    re.IGNORECASE,
)
UNVERIFIED_DISCLOSURE = re.compile(
    r"\bdid\s+not\s+(?:actually\s+)?(?:verify|check|call|run|hit|test)\b"
    r"|\bhave\s+not\s+(?:verified|checked|called|run|tested)\b"
    r"|\bwithout\s+(?:actually\s+)?(?:calling|running|hitting|querying)\b"
    r"|\bbased\s+(?:only\s+)?on\s+reading\s+the\s+code\b"
    r"|\bunverified\b|\bnot\s+verified\b|\bfrom\s+the\s+code\s+alone\b"
    r"|\bhypothes[ie]s\b|\bi\s+have\s+not\s+run\b",
    re.IGNORECASE,
)

if (not probed
        and VERIFY_CLAIM.search(final_text)
        and EXTERNAL_SUBJECT.search(final_text)
        and not UNVERIFIED_DISCLOSURE.search(final_text)):
    block(
        "Grounding gate: your message claims you VERIFIED something about an external system "
        "(an API, endpoint, or request), but this turn made no call that could reach one — no "
        "Bash, no WebFetch, no WebSearch. Reading the function that performs a request is not "
        "performing it, and a report headed 'verified' that was never verified is worse than no "
        "report: it ends the investigation at a guess wearing the costume of a finding. Before "
        "ending the turn, either (a) actually run it NOW — one curl or one command against the "
        "real thing — and report what it returned, or (b) label the claim honestly: say it is "
        "inferred from reading the code and NOT verified against the live system, and name the "
        "one command that would settle it."
    )

# --- Check 3d: UNVERIFIED DEPLOY CLAIM — "Deployed." with nothing that touched
# the deployed surface.
#
# Measured (user report, 2026-08-16): "Deployed. … Build verified, pushed to
# deploy branch. Vercel auto-deploy will pick it up." The fix was not live. No
# workflow in that repo triggers on a push to `deploy` — the branch is a data and
# history branch, and its own workflow header says a data refresh no longer
# deploys. Nothing was watching. The user had already recorded this exact gotcha
# in memory ("pushing `deploy` does NOT deploy"), so the turn contradicted a
# known fact AND asserted an outcome it never observed.
#
# Why 3c misses it: the turn DID run Bash — a build and a git push — so it looks
# probed. But a build and a push both succeed locally while production keeps
# serving the old bundle. "It built and I pushed" is evidence about THIS machine;
# "it is deployed" is a claim about a machine somewhere else. The gap between
# those two is exactly where this failure lives, and it is invisible to every
# check that only asks "did any tool run?".
#
# So the bar is specific: a deploy claim requires something that reached the
# deployed surface or its control plane — curl/WebFetch against a non-local host,
# a `vercel`/`netlify`/`wrangler` call, `gh workflow run`, a rollout. Disclosure
# passes, as everywhere else: "pushed, NOT yet live, still needs X" is honest and
# is frequently the correct stop.
DEPLOY_CLAIM = re.compile(
    r"^\s*(?:✅\s*)?deployed\b"
    r"|\b(?:i|we)\s+(?:have\s+)?(?:deployed|shipped|released)\b"
    r"|\bdeployed\s+(?:to|it|the)\b"
    r"|\bis\s+(?:now\s+)?live\b|\bwent\s+live\b|\bnow\s+in\s+production\b"
    r"|\bauto[-\s]?deploy\s+will\b|\bwill\s+pick\s+(?:it|this|them)\s+up\b"
    r"|\bshould\s+be\s+live\b"
    # Measured gap (2026-08-16): the gate caught "auto-deploy WILL pick it up"
    # but not "Vercel WILL AUTO-DEPLOY the latest commit" — the same false claim
    # with the words in the other order. It also missed "will go live" and "the
    # deploy is done". Direction of the sentence is not the point; asserting that
    # deployment is handled is.
    r"|\bwill\s+auto[-\s]?deploy\b|\bwill\s+deploy\b"
    r"|\bwill\s+(?:go|be)\s+live\b"
    r"|\bdeploy(?:ment)?\s+is\s+(?:done|complete|finished)\b"
    r"|\bpushed\s+to\s+(?:the\s+)?deploy\b",
    re.IGNORECASE | re.MULTILINE,
)
DEPLOY_DISCLOSURE = re.compile(
    r"\bnot\s+(?:yet\s+)?(?:live|deployed|in\s+production)\b"
    r"|\bstill\s+needs?\s+(?:to\s+be\s+)?deploy"
    r"|\bhaven'?t\s+(?:verified|confirmed)\s+(?:it'?s\s+)?live\b"
    r"|\byou\s+(?:will\s+)?(?:still\s+)?(?:need|have)\s+to\s+(?:run|trigger|deploy)\b"
    r"|\bunverified\b|\bi\s+have\s+not\s+confirmed\b",
    re.IGNORECASE,
)

if (DEPLOY_CLAIM.search(final_text) and not live_probed
        and not user_is_question
        and not DEPLOY_DISCLOSURE.search(final_text)):
    block(
        "Deploy gate: your message says the change is deployed or about to go live, but nothing "
        "this turn touched the deployed surface — no request to the live host, no deploy CLI, no "
        "workflow run. A build and a git push both succeed on THIS machine while production keeps "
        "serving the old bundle, so neither is evidence of a deploy; 'it built and I pushed' and "
        "'it is live' are claims about two different computers. Before ending the turn, either "
        "(a) actually confirm it — trigger the real deploy path and fetch the live URL, and quote "
        "what came back — or (b) say plainly that it is pushed but NOT yet live, and name the "
        "exact step still required. Check the project's own notes first: a branch that looks like "
        "a deploy trigger often is not one."
    )

# --- Guard B applied: a hand-back to the user is a legitimate stop. Tested
# BEFORE the park check — WAIT_ON_USER already distinguishes "waiting on your
# call" (yield) from "waiting on the agent" (park). ---
if WAIT_ON_USER.search(closing2) or HANDBACK.search(closing2):
    sys.exit(0)

# --- Check 4 (D4): PARKED on our own background work ---
# D6 (2026-07-28): skip entirely while background work is STILL RUNNING. D4 exists
# for the turn that parks on a job it could have collected; when the job genuinely
# has not finished, the harness re-invokes us the moment it does, and the footer
# pill already shows what is in flight. Nudging anyway asks for a result that does
# not exist yet, so the only reply available is filler — observed live as
# "I am genuinely blocked because the background agents are still running. I will
# synthesize immediately upon completion.", printed turn after turn. Silence here
# reads as thinking/waiting, which is what the user asked to see instead.
# Absent key (older build) ⇒ 0 ⇒ every check behaves exactly as before.
#
# Placed ahead of Check 4 so it also covers Check 5 and Check 1, which sit further
# down and fire on the SAME sentence: "I will synthesize once they complete" is an
# announced-next-step to the stall check and a park to D4. Suppressing only D4 just
# hands the turn to Check 1 — measured, not assumed: with D4 alone guarded, the
# user's verbatim text still blocked with "You ended your turn on an announced next
# step (\"I will synthesize…\")". That is the loop they reported.
#
# Gated on PARKED so the exemption stays narrow: it means "the wait is on our own
# background job", which is only truthful while one is actually running. A bare
# "let me go verify that" alongside an unrelated agent is still a stall and still
# blocks.
BG_RUNNING = int(d.get("background_tasks_running") or 0)
if BG_RUNNING > 0 and (
    PARKED.search(closing)
    or PARKED.search(tail)
    or BG_CONTINGENT.search(closing)
    or BG_CONTINGENT.search(tail)
):
    sys.exit(0)

if (PARKED.search(closing) or PARKED.search(tail)) and not USER_ACTIONABLE.search(closing2):
    block(
        "You ended your turn parked on background work you dispatched yourself — the user is "
        "not the blocker, your own job is. Do not hand an unfinished turn back and wait to be "
        "prodded. Collect the results NOW (poll/await the task, read its output, or do the work "
        "directly if that is faster) and report what you actually got. Only if collecting is "
        "genuinely impossible from here, say so in one line and state exactly what you are "
        "waiting on and what you will do with it."
    )

# --- Check 5: PLAN-PRESENTED-BUT-NOT-EXECUTED ---
# The stall check keys on an announcement verb ("let me…", "I'll…"). A bare
# numbered plan has none — serge lists the steps and stops, and the user has to
# type "do it". Same flow break, no verb to catch it by.
#
# Fires only when the message ENDS on a list of ≥2 forward-looking steps, the
# user gave an order, and NOTHING was built this turn. A recap of completed work
# ("Fixed X / Added Y") is past-tense and does not match; a plan-mode turn, a
# plan/advice request, and a turn that produced edits are all exempt.
LIST_ITEM = re.compile(r"^\s*(?:\d+[.)]|[-*+])\s+(.{3,})$")
STEP_FUTURE = re.compile(
    r"^\**\s*(?:(?:then|next|first|finally|now)\s+)?"
    r"(?:i\s+(?:will|'ll)\s+|we\s+(?:will|'ll)\s+|will\s+)?"
    r"(?:add|fix|make|build|implement|update|create|change|remove|delete|rename|move|"
    r"write|refactor|wire|port|migrate|run|install|configure|hook|integrate|apply|patch|"
    r"split|merge|extend|replace|switch|bump|verify|test|check|read|inspect|audit|scan|"
    r"measure|profile|guard|handle|expose|document|set\s+up|clean\s+up)\b",
    re.IGNORECASE,
)
STEP_PAST = re.compile(
    r"^\**\s*(?:added|fixed|made|built|implemented|updated|created|changed|removed|deleted|"
    r"renamed|moved|wrote|refactored|wired|ported|migrated|ran|installed|configured|hooked|"
    r"integrated|applied|patched|split|merged|extended|replaced|switched|bumped|verified|"
    r"tested|checked|read|inspected|audited|scanned|measured|profiled|documented|confirmed)\b",
    re.IGNORECASE,
)
PLAN_HEADING = re.compile(
    r"^\s*(?:#{1,6}\s*)?\**\s*(?:the\s+)?(?:plan|steps?|approach|proposal|next\s+steps?|"
    r"implementation(?:\s+plan)?|what\s+i(?:'ll| will)\s+do|to\s+do|todo)\b[:\s*]*$",
    re.IGNORECASE | re.MULTILINE,
)

def trailing_steps(t):
    """The maximal run of list items the message ENDS on (blank lines allowed)."""
    items = []
    for raw in reversed(t.splitlines()):
        line = raw.rstrip()
        if not line.strip():
            if items:
                continue
            continue
        m = LIST_ITEM.match(line)
        if m:
            items.append(m.group(1).strip())
            continue
        break                      # prose after the list → not ending on a plan
    return list(reversed(items))

steps = trailing_steps(body)
# A MENU is not a plan. "- **Research**: … - **Configuration**: …" and
# "migrate to a container host (e.g. Vercel, a VPS, or Fly)" are options being
# offered, not steps being committed to — pushing serge to "execute step 1"
# there means picking for the user. Labelled options and or-lists are excluded.
OPTION_ITEM = re.compile(r"^\*{0,2}[A-Z][\w /-]{2,28}\*{0,2}\s*:", re.MULTILINE)
menu_like = (bool(FORK.search(tail))
             or sum(bool(OPTION_ITEM.match(s)) for s in steps) * 2 >= len(steps))
if (len(steps) >= 2 and user_is_order and not code_edits and not IN_PLAN_MODE
        and not cm and not menu_like
        and sum(bool(STEP_PAST.match(s)) for s in steps) * 2 < len(steps)
        and (PLAN_HEADING.search(tail) or
             sum(bool(STEP_FUTURE.match(s)) for s in steps) >= 2)):
    first = re.sub(r"\s+", " ", steps[0]).strip()[:70]
    block(
        f"You ended the turn on a {len(steps)}-step plan without executing any of it, and this "
        f"turn changed no code. The user asked you to do the work, not to describe it — a plan "
        f"that stops at the plan is the same flow break as trailing off mid-sentence. Start "
        f'step 1 now ("{first}…") and keep going through the list in this same turn. If a step '
        "genuinely needs a decision only the user can make, do every step before it first, then "
        "ask that ONE question."
    )

# --- Check 1: STALL — announced-but-untaken next action ---
# (a) first-person modal announcements.
ANNOUNCE_MODAL = re.compile(
    r"\b("
    r"let me (?!know\b)\w+"
    r"|let'?s (?!know\b)\w+|let us \w+"
    r"|i'?ll (?:now |go ahead and |just |then |first |also |quickly |next |start by )?\w+"
    r"|i will (?:now |also |first |go ahead and )?\w+"
    r"|i'?m (?:going to|gonna|about to) \w+|i am (?:going to|about to) \w+"
    r"|next,?\s+i'?ll|now i'?ll|then i'?ll|next,?\s+let me|now,?\s+let me"
    r"|i need to (?!know\b)\w+|i should \w+"
    r"|time to \w+|allow me to \w+|i'?d like to \w+"
    r"|the fix is to|first,?\s+i'?ll|let me go\b|i can now \w+"
    # Past-tense announcement — the intent was formed and then dropped:
    # "I was about to implement the extractor. That's the remaining two steps."
    r"|i was (?:about to|going to|planning to|just about to) \w+"
    r"|that'?s (?:the )?remaining\b|the remaining (?:two|three|four|\d+) steps?\b"
    r"|(?:what'?s|that is) left (?:to do )?is\b"
    r"|going to (?:check|verify|run|look|read|test|inspect|examine|investigate|"
    r"dig|trace|confirm|fix|start|open|search|grep|fetch|pull|review)"
    r")",
    re.IGNORECASE,
)
# (b) D3: telegraphic / participle announcements — "Checking the config now…",
#     "On it — pulling up the logs.", "Investigating the stream handler."
ACTION_ING = (r"check|verif|run|test|look|read|inspect|examin|investigat|dig|trac|"
              r"profil|scan|search|grep|fetch|pull|load|open|start|kick|build|compil|"
              r"rebuild|rerun|re-run|confirm|validat|measur|hunt|review|audit|explor|"
              r"gather|collect|wir|hook|patch|fix|updat|writ|creat|add")
ANNOUNCE_TELEGRAPHIC = re.compile(
    r"^(?:ok(?:ay)?|alright|right|good|great|got it|understood|perfect|sure)?[,.!—–-]*\s*"
    r"(?:now|next|first|then|so)?[,.!—–-]*\s*"
    r"(?:(?:" + ACTION_ING + r")\w*ing\b"
    r"|on it\b|one sec\b|one moment\b|hang on\b|hold on\b|stand by\b|here goes\b|"
    r"give me a (?:sec|moment|minute)\b|moment\b|doing that now\b|right away\b)",
    re.IGNORECASE,
)
# A finding that merely *starts* with a participle is a report, not a plan.
REPORT_MARKER = re.compile(
    r"\b(?:is|are|was|were|has|have|had|gave|shows?|showed|reveals?|revealed|"
    r"returns?|returned|found|confirms?|confirmed|passes|passed|fails?|failed|"
    r"yields?|yielded|means?|meant|because|since|so that|which|worked|works)\b",
    re.IGNORECASE,
)
# The closing reads as a finished report / sign-off (narrow, and only used to
# veto the whole-tail backstop below — never a stall in the closing itself).
COMPLETION = re.compile(
    r"(?:✅|\ball set\b|\ball done\b|\bnothing left\b|\bready for review\b|"
    r"\bfully fixed\b|\bthat'?s everything\b|\b(?:is|are|now) complete\b|"
    r"\btask complete\b|\bi'?m done\b|\bwe'?re done\b|\bno further\b|"
    r"\bin summary\b|\bto summari[sz]e\b|\bsummary:)",
    re.IGNORECASE,
)

hit = ANNOUNCE_MODAL.search(closing)
# A bulleted participle enumerates ("- Verifying the page loads"); it does not
# announce. Only free-standing prose counts for the telegraphic class.
if not hit and not closing_is_bullet and len(closing) <= 140 \
        and ANNOUNCE_TELEGRAPHIC.search(closing) \
        and not REPORT_MARKER.search(closing):
    hit = ANNOUNCE_TELEGRAPHIC.search(closing)
if not hit and not COMPLETION.search(closing) and not COMPLETION.search(closing2):
    # Backstop: announcement earlier in the tail, closing is not a sign-off.
    hit = ANNOUNCE_MODAL.search(tail)

if not hit:
    sys.exit(0)

snippet = re.sub(r"\s+", " ", hit.group(0)).strip()[:90]
block(
    f'You ended your turn on an announced next step ("{snippet}…") without carrying it out. '
    "Per your persistence rule, do NOT stop here — take that action now, in this same turn, "
    "and keep going until the task is actually complete. If you are genuinely blocked (a decision "
    "only the user can make) or the task is truly finished, say so explicitly with a one-line "
    "summary instead of trailing off on a plan."
)
PY
