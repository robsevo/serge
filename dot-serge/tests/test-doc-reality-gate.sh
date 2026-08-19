#!/usr/bin/env bash
# Tests for doc-reality-gate.sh — $0, no LLM, no network. A throwaway workspace
# with a known package.json / Makefile / tree is built in TMPDIR, so every
# assertion is against filesystem truth rather than the real repo.
set -uo pipefail

HOOK="${SERGE_DOC_GATE_SCRIPT:-$HOME/.serge/doc-reality-gate.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export TMPDIR="$T"          # isolates the block-once markers
W="$T/ws"; mkdir -p "$W/src/tools" "$W/docs" "$W/claudedocs" "$W/scripts"
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }

cat > "$W/package.json" <<'JSON'
{ "name": "ws", "scripts": { "build": "bun run scripts/build.ts", "test": "bun test", "docs:api": "typedoc" } }
JSON
cat > "$W/Makefile" <<'MAKE'
.PHONY: release clean
release:
	@echo release
clean:
	@echo clean
MAKE
: > "$W/src/tools/real.ts"
: > "$W/scripts/build.ts"

# run <session> <relative doc path> <content> [tool] — prints the hook's
# stdout+stderr and RETURNS its exit code. It must be a return value, not a
# global: every caller wraps this in $( ), which is a subshell, so an assignment
# to a global here would never reach the caller.
run() {
  local sid="$1" rel="$2" body="$3" tool="${4:-Write}"
  python3 -c '
import json, sys, os
tool = sys.argv[4]
ti = {"file_path": os.path.join(sys.argv[2], sys.argv[3])}
if tool == "Write":
    ti["content"] = sys.argv[5]
elif tool == "Edit":
    ti["new_string"] = sys.argv[5]
else:
    ti["edits"] = [{"new_string": sys.argv[5]}]
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": tool,
                  "session_id": sys.argv[1], "cwd": sys.argv[2],
                  "tool_input": ti}))
' "$sid" "$W" "$rel" "$tool" "$body" | bash "$HOOK" 2>&1
  return "${PIPESTATUS[1]}"
}
blocks() {  # blocks <label> <session> <path> <body> <expected substring>
  local out rc; out=$(run "$2" "$3" "$4"); rc=$?
  if [ "$rc" = "2" ] && printf '%s' "$out" | grep -q "$5"; then ok "$1"
  else bad "$1 — rc=$rc out=${out:0:160}"; fi
}
silent() {  # silent <label> <session> <path> <body>
  local out rc; out=$(run "$2" "$3" "$4"); rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then ok "$1"
  else bad "$1 — fired rc=$rc out=${out:0:160}"; fi
}

echo "── A. script commands ──"
blocks "missing npm script"     a1 README.md 'Run `bun run docs:build` to build.'   "no such script"
blocks "missing make target"    a2 README.md 'Then `make deploy`.'                  "no such target"
silent "real npm script"        a3 README.md 'Run `bun run build`, then `npm run docs:api`.'
silent "real make target"       a4 README.md 'Then `make release` and `make clean`.'
silent "builtin, not a script"  a5 README.md 'Run `bun test` and `npm install` first.'
silent "run <file> is not a script name" a6 README.md 'Do not call `bun run scripts/build.ts` directly.'
silent "run ./file is not a script name" a7 README.md 'Use `npm run ./tools/x.mjs` if you must.'

echo
echo "── B. repo paths ──"
blocks "missing file under a real dir" b1 README.md 'See `src/tools/ghost.ts` for details.' "no such file"
silent "real file"              b2 README.md 'See `src/tools/real.ts` for details.'
silent "real dir"               b3 README.md 'Everything lives under `src/tools/`.'
silent "placeholder path"       b4 README.md 'Put it in `path/to/your/config.json`.'
silent "unrooted path"          b5 README.md 'Compare with `some-other-project/src/main.ts`.'
silent "absolute path"          b6 README.md 'Config lives at `/etc/ws/config.toml`.'
silent "home path"              b7 README.md 'Config lives at `~/.ws/config.toml`.'
silent "url is not a path"      b8 README.md 'See https://example.com/docs/install for more.'
silent "glob is not a path"     b9 README.md 'Matches `src/tools/*.ts` in the tree.'

echo
echo "── C. block-once, then advisory ──"
out=$(run c1 README.md 'Run `bun run nope`.'); rc=$?
if [ "$rc" = "2" ]; then ok "first offence blocks"; else bad "first offence rc=$rc"; fi
out=$(run c1 README.md 'Run `bun run nope` again.'); rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'not blocking again'; then
  ok "same session+file → advisory, never a dead end"
else bad "second offence rc=$rc out=${out:0:160}"; fi
out=$(run c2 README.md 'Run `bun run nope`.'); rc=$?
if [ "$rc" = "2" ]; then ok "a different session blocks again"; else bad "new session rc=$rc"; fi

echo
echo "── D. scope ──"
silent "non-doc file ignored"   d1 src/tools/real.ts 'bun run nope'
silent "claudedocs is proposals" d2 claudedocs/plan.md 'We will add `src/services/new/thing.ts` via `bun run nope`.'
silent "sample docs are templates" d3 docs/reference-samples.md 'Create `src/tools/galaxy.ts` and run `bun run nope`.'
blocks "ordinary docs/ file is checked" d4 docs/install.md 'Run `bun run nope`.' "no such script"

echo
echo "── E. edit shapes ──"
out=$(run e1 README.md 'Run `bun run nope`.' Edit); rc=$?
if [ "$rc" = "2" ]; then ok "Edit new_string is checked"; else bad "Edit rc=$rc out=${out:0:120}"; fi
out=$(run e2 README.md 'Run `bun run nope`.' MultiEdit); rc=$?
if [ "$rc" = "2" ]; then ok "MultiEdit edits[] are checked"; else bad "MultiEdit rc=$rc out=${out:0:120}"; fi

echo
echo "── F. fail-open and off-switch ──"
out=$(SERGE_DOC_GATE_DISABLE=1 run f1 README.md 'Run `bun run nope`.'); rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then ok "SERGE_DOC_GATE_DISABLE=1 → inert"
else bad "off-switch ignored rc=$rc out=${out:0:120}"; fi
mv "$W/package.json" "$W/package.json.off"; printf 'not json{' > "$W/package.json"
out=$(run f2 README.md 'Run `bun run nope`.'); rc=$?
if [ "$rc" = "0" ]; then ok "unparseable package.json → fails open"
else bad "broken manifest still blocked rc=$rc"; fi
mv "$W/package.json.off" "$W/package.json"
out=$(printf '{"hook_event_name":"PostToolUse"}' | bash "$HOOK" 2>&1); rc=$?
if [ "$rc" = "0" ] && [ -z "$out" ]; then ok "malformed payload → fails open"
else bad "malformed payload rc=$rc out=${out:0:120}"; fi

echo
if [ "$fail" -eq 0 ]; then echo "✓ ALL $pass PASS — doc-reality gate"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
