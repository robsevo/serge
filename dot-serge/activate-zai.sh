#!/usr/bin/env bash
# Activate the Z.AI GLM-4.7-Flash seats — repoints glm-coder + free-scout off
# Cerebras (hard 8,192-token cap) onto Z.AI (200,000-token context, still $0).
#
# WHY THIS EXISTS: glm-coder and free-scout are structurally dead. Both point at
# `cerebras/zai-glm-4.7`, which Cerebras' free tier hard-caps at 8,192 tokens
# while serge's MEDIAN request is ~74,700 — so every real turn silently fell
# through to gemini-3.1-flash-lite (the most quota-fragile provider we have).
# litellm 1.88.1 already knows `zai/glm-4.7-flash`: max_input_tokens 200000,
# input/output cost 0, supports_function_calling True, base URL built in.
#
# SAFETY: this script proves the key works and the model passes serge's real
# acceptance gates (75K-token context AND a genuine tool_call) BEFORE it touches
# any live config. Z.AI tool-calling was never verified in the original research
# — if it fails the gate, nothing is changed and the seats stay as they are.
#
# Usage:
#   ~/.serge/activate-zai.sh <api-key>
#   ZAI_API_KEY=<key> ~/.serge/activate-zai.sh
#   ~/.serge/activate-zai.sh --dry-run <api-key>   # gates only, no writes
#
# Get a key at https://z.ai (Z.AI API keys / API console). Free tier, no card.
set -uo pipefail

SERGE_HOME="${SERGE_HOME:-$HOME/.serge}"
DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
KEY="${1:-${ZAI_API_KEY:-}}"

if [ -z "$KEY" ]; then
  echo "activate-zai: no key given." >&2
  echo "  usage: $0 <api-key>       (get one at https://z.ai — free, no card)" >&2
  exit 2
fi

ENVF="$SERGE_HOME/router.env"
YAML="$SERGE_HOME/litellm.yaml"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "==> [1/5] validating the key against Z.AI BEFORE writing it anywhere"
# Validate-before-write is the rotation procedure that worked for the Mistral
# key: never persist a credential that has not answered a real request.
code=$(curl -s -o /tmp/.zai_probe.$$ -w '%{http_code}' -m 60 \
  https://api.z.ai/api/paas/v4/chat/completions \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"glm-4.7-flash","max_tokens":8,"messages":[{"role":"user","content":"Reply OK."}]}')
if [ "$code" != "200" ]; then
  echo "    FAILED — HTTP $code" >&2
  head -c 300 /tmp/.zai_probe.$$ >&2; echo >&2
  rm -f /tmp/.zai_probe.$$
  echo "    Nothing was changed. Check the key at https://z.ai" >&2
  exit 1
fi
rm -f /tmp/.zai_probe.$$
echo "    key is live (HTTP 200)"

echo "==> [2/5] acceptance gates: 75K context + a REAL tool_call"
if ! ZAI_API_KEY="$KEY" bash "$SERGE_HOME/probe-candidate.sh" \
      --base https://api.z.ai/api/paas/v4 --key-env ZAI_API_KEY \
      --models glm-4.7-flash; then
  echo "    Z.AI failed serge's acceptance gates — NOT activating." >&2
  echo "    Live config untouched; glm-coder/free-scout unchanged." >&2
  exit 1
fi

if [ "$DRY" = "1" ]; then
  echo "==> dry run: gates passed, no files written."
  exit 0
fi

echo "==> [3/5] writing the key to router.env (backup + chmod 600)"
cp -p "$ENVF" "$SERGE_HOME/backups/router.env.$STAMP.pre-zai.bak" 2>/dev/null || true
if command grep -q '^ZAI_API_KEY=' "$ENVF" 2>/dev/null; then
  tmp=$(mktemp); sed "s|^ZAI_API_KEY=.*|ZAI_API_KEY=$KEY|" "$ENVF" > "$tmp"
  cat "$tmp" > "$ENVF"; rm -f "$tmp"          # preserve inode/perms
else
  printf '\n# Z.AI (GLM-4.7-Flash, free tier, 200K context) — added %s\nZAI_API_KEY=%s\n' \
    "$(date +%Y-%m-%d)" "$KEY" >> "$ENVF"
fi
chmod 600 "$ENVF"
echo "    router.env updated (mode 600)"

echo "==> [4/5] repointing glm-coder + free-scout in litellm.yaml"
cp -p "$YAML" "$SERGE_HOME/backups/litellm.yaml.bak-zai-$STAMP" 2>/dev/null || true
python3 - "$YAML" <<'PY'
import sys, re
p = sys.argv[1]
lines = open(p).read().split("\n")
out, changed = [], 0
i = 0
while i < len(lines):
    line = lines[i]
    out.append(line)
    m = re.match(r'^(\s*)- model_name: (glm-coder|free-scout)\s*$', line)
    if m:
        indent = m.group(1)
        # Rewrite this deployment's litellm_params block (until the next
        # `- model_name:` or a dedent), leaving every comment intact.
        j = i + 1
        block = []
        while j < len(lines):
            nxt = lines[j]
            if re.match(r'^\s*- model_name:', nxt):
                break
            if nxt.strip() and not nxt.startswith(indent + "  "):
                break
            block.append(nxt)
            j += 1
        newblock, seen_tpm = [], False
        for b in block:
            # Match the model/api_key lines by POSITION (inside this seat's
            # block), not by their current VALUE. The original version hard-coded
            # `cerebras/zai-glm-4.7` / `CEREBRAS_API_KEY`, which silently rotted
            # the moment those seats were repointed: on 2026-08-14 both moved off
            # the dead Cerebras GLM (8,192-token cap) onto stand-ins, and this
            # script would then have matched 0 of 2 and aborted — a repair tool
            # that breaks precisely because the damage it repairs got worked
            # around. Value-agnostic matching survives any future repointing.
            if re.match(r'^\s*model:\s*\S+\s*$', b):
                newblock.append(indent + "    model: zai/glm-4.7-flash"); changed += 1
            elif re.match(r'^\s*api_key:\s*os\.environ/\S+\s*$', b):
                newblock.append(indent + "    api_key: os.environ/ZAI_API_KEY")
            elif re.match(r'^\s*rpm:\s*\d+\s*$', b):
                # Z.AI free is ~1 req/s; 20 leaves headroom under that.
                newblock.append(indent + "    rpm: 20")
            elif re.match(r'^\s*tpm:\s*\d+\s*$', b):
                # 55000 was chosen for Cerebras' 60K TPM. Z.AI publishes no TPM,
                # so an invented cap would be worse than none.
                seen_tpm = True
                continue
            else:
                newblock.append(b)
        out.extend(newblock)
        i = j
        continue
    i += 1
open(p, "w").write("\n".join(out))
print("    rewrote %d deployment(s)" % changed)
if changed != 2:
    print("    WARNING: expected 2, got %d — inspect the file" % changed)
    sys.exit(1)
PY
[ $? -ne 0 ] && { echo "    yaml rewrite failed — restoring backup" >&2
                  cp -p "$SERGE_HOME/backups/litellm.yaml.bak-zai-$STAMP" "$YAML"; exit 1; }
python3 -c "import yaml,sys;yaml.safe_load(open('$YAML'))" || {
  echo "    yaml is invalid after rewrite — restoring backup" >&2
  cp -p "$SERGE_HOME/backups/litellm.yaml.bak-zai-$STAMP" "$YAML"; exit 1; }

echo "==> [5/5] restarting the router and verifying the seats"
systemctl --user restart serge-router.service
t0=$(date +%s)
until curl -s -m 3 -o /dev/null http://127.0.0.1:4000/v1/models 2>/dev/null; do
  [ $(( $(date +%s) - t0 )) -gt 300 ] && { echo "    router did not come back" >&2; exit 1; }
  sleep 2
done
echo "    router up after $(( $(date +%s) - t0 ))s"
bash "$SERGE_HOME/seat-health.sh" --seats glm-coder,free-scout

echo ""
echo "Done. Run ~/programs/serge-portable/sync-portable.sh to mirror the change."
