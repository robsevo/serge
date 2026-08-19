#!/usr/bin/env bash
# Serge claims gate — independent verification of falsifiable claims ($0 for
# file/cmd claims, one HTTP GET per url claim).
#
# WHY (user, 2026-08-16, quoting the agent-reliability literature): "an agent's
# 'done' signal is merely a statistical prediction of a successful conclusion,
# not proof that the task was successfully executed." Every other gate in this
# house infers intent by REGEX OVER PROSE — did the message look like a
# done-claim, did it mention a test. That works, and it caught four real
# failures this week, but it is heuristic in both directions: prose can imply
# work that never happened, and can describe real work in a shape no regex
# matches.
#
# This gate inverts the burden. Instead of reading what Serge SAID, it re-checks
# what Serge CLAIMED against the filesystem, the transcript, and the network:
#
#   <claims>
#   file /abs/path.ts sha256=<64hex>     → re-hashed here, now
#   file /abs/path.ts exists             → re-stat'd here, now
#   cmd  "bun test" exit=0               → must appear in THIS turn's transcript
#                                          with a clean result (and is re-run
#                                          when SERGE_CLAIMS_RERUN=1)
#   url  https://host/path status=200    → re-fetched here, now
#   </claims>
#
# A claim that does not match reality blocks the turn and is quoted back with
# the observed value. The point is not to catch a liar; it is that a model
# cannot predict its way past a sha256 it did not compute.
#
# DESIGN NOTES
#   - file/url claims are verified INDEPENDENTLY (we stat and fetch ourselves).
#     cmd claims are checked against the transcript record by default, because
#     re-running an arbitrary command at stop time is a side-effect hazard and
#     re-running a real suite costs ~55s on every turn. SERGE_CLAIMS_RERUN=1
#     opts into real re-execution for allowlisted test/typecheck/lint commands.
#   - NO CLAIMS BLOCK IS NOT AN ERROR. This gate only judges claims that were
#     made. Requiring a block on every turn would make it a tax on conversation;
#     the constitution asks for one when work was done, and the other gates
#     already cover unclaimed work.
#   - Fails OPEN on any parse error, timeout, or unreadable input. A gate that
#     cannot read its input has proved nothing.
#
# Off-switch: SERGE_CLAIMS_GATE_DISABLE=1
set -uo pipefail

[ "${SERGE_CLAIMS_GATE_DISABLE:-0}" = "1" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"

OUT="$(python3 - "$input" <<'PY'
import sys, json, os, re, hashlib, subprocess, shlex

try:
    d = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
except Exception:
    sys.exit(0)

final = (d.get("last_assistant_message") or "").strip()
tx = d.get("transcript_path") or ""

# Fall back to the transcript when the harness did not hand us the text in-band.
if not final and tx and os.path.exists(tx):
    try:
        last = ""
        with open(tx, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"assistant"' not in line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("type") != "assistant":
                    continue
                texts = [b.get("text", "") for b in (e.get("message") or {}).get("content") or []
                         if isinstance(b, dict) and b.get("type") == "text"]
                if texts:
                    last = "\n".join(texts)
        final = last.strip()
    except Exception:
        sys.exit(0)

if not final:
    sys.exit(0)

m = re.search(r"<claims>(.*?)</claims>", final, re.S | re.I)
if not m:
    sys.exit(0)          # no claims made — nothing for THIS gate to judge
body = m.group(1)

# ── collect what the turn actually ran, for cmd claims ───────────────────────
ran = {}   # normalised command -> "clean" | "failed"
if tx and os.path.exists(tx):
    FAIL = re.compile(r"\b[1-9]\d*\s+fail|\bexit(?:\s+code)?\s*[:=]?\s*[1-9]|\berror\s+TS\d+", re.I)
    FAIL_CS = re.compile(r"\bFAILED\b|\bFAILURES\b|\bAssertionError\b|\bTraceback\b")
    pend = {}
    try:
        with open(tx, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                msg = e.get("message") or {}
                for b in msg.get("content") or []:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use" and b.get("name") == "Bash":
                        cid = b.get("id")
                        cmd = str((b.get("input") or {}).get("command") or "")
                        if cid:
                            pend[cid] = " ".join(cmd.split())
                    elif b.get("type") == "tool_result":
                        cid = b.get("tool_use_id")
                        if cid in pend:
                            out = b.get("content")
                            if isinstance(out, list):
                                out = " ".join(x.get("text", "") for x in out if isinstance(x, dict))
                            out = str(out or "")
                            bad = bool(b.get("is_error")) or bool(FAIL.search(out)) or bool(FAIL_CS.search(out))
                            ran[pend.pop(cid)] = "failed" if bad else "clean"
    except Exception:
        pass

RERUN_OK = re.compile(r"^\s*(?:bun|npm|npx|pnpm|yarn|pytest|python3?\s+-m\s+pytest|tsc|bunx\s+tsc|make|cargo|go)\b")
rerun = os.environ.get("SERGE_CLAIMS_RERUN") == "1"

bad = []
checked = 0

for raw in body.splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split(None, 1)
    if len(parts) < 2:
        continue
    kind, rest = parts[0].lower(), parts[1].strip()

    # ── file <path> [sha256=<hex> | exists] ──────────────────────────────────
    if kind == "file":
        mm = re.match(r"(\S+)\s*(.*)$", rest)
        if not mm:
            continue
        path, assertion = mm.group(1), mm.group(2).strip()
        path = os.path.expanduser(path)
        checked += 1
        if not os.path.exists(path):
            bad.append(f"file {path} — claimed to exist; it does NOT exist on disk")
            continue
        sm = re.search(r"sha256=([0-9a-fA-F]{8,64})", assertion)
        if sm:
            try:
                h = hashlib.sha256(open(path, "rb").read()).hexdigest()
            except OSError as e:
                bad.append(f"file {path} — unreadable ({e})")
                continue
            claimed = sm.group(1).lower()
            if not h.startswith(claimed):
                bad.append(f"file {path} — claimed sha256={claimed}…, actual sha256={h[:len(claimed)]}…")

    # ── cmd "<command>" exit=<n> ─────────────────────────────────────────────
    elif kind == "cmd":
        cm = re.match(r"[\"'](.+?)[\"']\s*(.*)$", rest) or re.match(r"(\S+)\s*(.*)$", rest)
        if not cm:
            continue
        cmd = " ".join(cm.group(1).split())
        want = re.search(r"exit=(\d+)", cm.group(2) or "")
        want_code = int(want.group(1)) if want else 0
        checked += 1
        if rerun and RERUN_OK.match(cmd):
            try:
                rc = subprocess.run(shlex.split(cmd), capture_output=True, timeout=600).returncode
            except Exception as e:
                bad.append(f'cmd "{cmd}" — could not be re-run ({type(e).__name__})')
                continue
            if rc != want_code:
                bad.append(f'cmd "{cmd}" — claimed exit={want_code}, re-ran and got exit={rc}')
            continue
        state = ran.get(cmd)
        if state is None:
            bad.append(f'cmd "{cmd}" — claimed, but this turn never ran it')
        elif state == "failed" and want_code == 0:
            bad.append(f'cmd "{cmd}" — claimed exit=0, but its output shows failures')

    # ── url <url> status=<n> ─────────────────────────────────────────────────
    elif kind == "url":
        um = re.match(r"(\S+)\s*(.*)$", rest)
        if not um:
            continue
        url, assertion = um.group(1), um.group(2)
        if not re.match(r"https?://", url):
            continue
        want = re.search(r"status=(\d{3})", assertion)
        checked += 1
        try:
            got = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "20", url],
                capture_output=True, text=True, timeout=30,
            ).stdout.strip()
        except Exception:
            continue          # network trouble proves nothing — fail open
        if want and got and got != want.group(1):
            bad.append(f"url {url} — claimed status={want.group(1)}, actual status={got}")

if not checked or not bad:
    sys.exit(0)

lines = [
    "Claims gate: %d of %d claim(s) in your <claims> block do not match reality."
    % (len(bad), checked)
]
for b in bad[:12]:
    lines.append("  " + b)
lines.append(
    "These were re-checked independently — the file was re-hashed, the command looked up in "
    "this turn's record, the URL re-fetched — so this is not a disagreement about wording. "
    "Fix the work until the claim is true, or correct the claim. Do not restate it."
)
print(json.dumps({"text": "\n".join(lines)}))
PY
)" || exit 0

[ -n "$OUT" ] || exit 0
TEXT="$(printf '%s' "$OUT" | python3 -c 'import sys,json; sys.stdout.write(json.load(sys.stdin).get("text",""))' 2>/dev/null)" || exit 0
[ -n "$TEXT" ] || exit 0

printf '%s' "$TEXT" | python3 -c '
import sys, json
print(json.dumps({"decision": "block", "reason": sys.stdin.read()}))'
exit 0
