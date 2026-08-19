#!/usr/bin/env bash
# Serge task evidence gate — TaskCompleted ($0, no LLM).
#
# WHY: a task whose own text says "test it" / "verify X" should not be markable
# complete while nothing in the session has actually run. This is the same rule
# the feature-flow stop gate already enforces for done-CLAIMS, applied to the
# other place "done" is asserted — the task list — which had no check at all.
#
# Deliberately NARROW, because an always-on blocker that misfires is worse than
# no blocker: it fires ONLY when the task's own subject/description explicitly
# asks for a test/verification, AND no verify-shaped command exited 0 anywhere in
# this session's transcript. A task that never mentioned testing is none of this
# hook's business.
#
# CONTRACT (verified): TaskCompleted carries task_id, task_subject,
# task_description? (coreTypes.generated.ts:588) and its blocking error is
# surfaced as "TaskCompleted hook feedback:" (hooks.ts:2124-2131). Exit 2 /
# decision:"block" prevents the task being marked complete. It canNOT inject
# additionalContext (not among the seven — hooks.ts:805-845).
#
# BLOCK ONCE per task_id: re-issuing completion goes through, so a task verified
# in a way this regex cannot see costs one turn, never a deadlock.
#
# Safety: off-switch SERGE_TASK_EVIDENCE_DISABLE=1 · fails open on any error ·
# reads only the tail of the transcript.
set -uo pipefail

[ "${SERGE_TASK_EVIDENCE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"

python3 - "$input" <<'PY'
import sys, json, os, re, hashlib

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].strip() else {}
except Exception:
    sys.exit(0)

if str(d.get("hook_event_name") or "") != "TaskCompleted":
    sys.exit(0)

subject = str(d.get("task_subject") or "")
desc = str(d.get("task_description") or "")
text = subject + "\n" + desc
if not text.strip():
    sys.exit(0)

# Does the TASK ITSELF ask for verification? If not, stay out of the way.
WANTS_TEST = re.compile(
    r"\b(test(s|ing|ed)?|verify|verif(y|ied|ication)|prove|regression|"
    r"make sure .{0,30}(works|passes)|check that .{0,30}(works|passes)|"
    r"typecheck|lint|build passes|green)\b", re.I)
if not WANTS_TEST.search(text):
    sys.exit(0)

tid = str(d.get("task_id") or "notask")
mark = os.path.join(os.environ.get("TMPDIR", "/tmp"),
                    "serge-taskgate-%s" % hashlib.sha1(tid.encode()).hexdigest()[:16])
if os.path.exists(mark):
    sys.exit(0)

tx = str(d.get("transcript_path") or "")
if not tx or not os.path.exists(tx):
    sys.exit(0)          # can't prove absence without the record → allow

VERIFY_RE = re.compile(
    r"\b(pytest|jest|vitest|bun test|npm (?:run )?test|yarn test|pnpm test|go test|"
    r"cargo test|make test|tox|mvn test|gradle test|rspec|phpunit|"
    r"tsc\b|typecheck|mypy|ruff|eslint|shellcheck|bash -n|"
    r"npm run build|bun run build|cargo build|make build|"
    r"\./tests?/[\w./-]+\.sh|test[-_][\w-]+\.sh)\b", re.I)

ran, ok_ids, fail_ids = {}, set(), set()
try:
    size = os.path.getsize(tx)
    with open(tx, "rb") as fh:
        if size > 8_000_000:
            fh.seek(size - 8_000_000)
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
    c = (e.get("message") or {}).get("content")
    if not isinstance(c, list):
        continue
    for b in c:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "tool_use" and b.get("name") == "Bash":
            cmd = (b.get("input") or {}).get("command")
            if isinstance(cmd, str) and VERIFY_RE.search(cmd):
                ran[str(b.get("id"))] = cmd.strip()
        elif b.get("type") == "tool_result":
            (fail_ids if b.get("is_error") else ok_ids).add(str(b.get("tool_use_id")))

passed = [c for i, c in ran.items() if i in ok_ids and i not in fail_ids]
if passed:
    sys.exit(0)          # evidence exists → complete away

try:
    open(mark, "w").close()
except Exception:
    pass

attempted = [c for i, c in ran.items() if i in fail_ids]
extra = ("\n\nVerification commands DID run but did not exit 0: %s — a failing "
         "check is not a completed task." % "; ".join(c[:80] for c in attempted[:2])
         ) if attempted else ""

print(json.dumps({
    "decision": "block",
    "reason": (
        "This task asks to be tested or verified (%r), but nothing in this "
        "session's transcript is a verification command that exited 0.%s\n\n"
        "Run the actual check and let it pass, then mark it complete. If it was "
        "verified in a way this gate cannot see — a manual check, a command run "
        "outside this session — say so explicitly in your next message and "
        "re-issue the completion; it will go through."
        % (subject[:80], extra)
    ),
}))
PY
exit 0
