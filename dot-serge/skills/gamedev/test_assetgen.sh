#!/usr/bin/env bash
# B.3 tests for assetgen.py: validation, determinism (known-answer), range,
# and the REAL integration — Godot 4 headless loads the generated assets.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="${SERGE_OFFICE_PY:-$HOME/.serge/office-venv/bin/python3}"
AG="$HERE/assetgen.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { echo "✓ $1"; pass=$((pass+1)); }
bad() { echo "✗ $1"; fail=$((fail+1)); }
[ -x "$PY" ] || { echo "SKIP: office-venv python not found at $PY"; exit 1; }

# 1. validation: bad inputs fail LOUDLY (nonzero + message), no silent defaults
r1=$("$PY" "$AG" sfx "$T/x.wav" --kind laser --seed 1 2>&1; echo "rc=$?")
r2=$("$PY" "$AG" sprite "$T/x.png" --seed 1 --size 15 2>&1; echo "rc=$?")
if printf '%s' "$r1" | grep -q "rc=1" && printf '%s' "$r1" | grep -q "unknown sfx kind" \
   && printf '%s' "$r2" | grep -q "rc=1"; then
  ok "invalid kind / odd size rejected loudly"
else bad "validation soft-failed (r1=$r1 r2=$r2)"; fi

# 2. determinism known-answer: same seed = identical bytes; new seed = different
"$PY" "$AG" sprite "$T/a1.png" --seed 42 >/dev/null && "$PY" "$AG" sprite "$T/a2.png" --seed 42 >/dev/null
"$PY" "$AG" sprite "$T/b.png" --seed 43 >/dev/null
"$PY" "$AG" sfx "$T/s1.wav" --kind coin --seed 7 >/dev/null && "$PY" "$AG" sfx "$T/s2.wav" --kind coin --seed 7 >/dev/null
h() { sha1sum "$1" | cut -d' ' -f1; }
if [ "$(h "$T/a1.png")" = "$(h "$T/a2.png")" ] && [ "$(h "$T/a1.png")" != "$(h "$T/b.png")" ] \
   && [ "$(h "$T/s1.wav")" = "$(h "$T/s2.wav")" ]; then
  ok "deterministic: same seed byte-identical, new seed differs"
else bad "determinism broken"; fi

# 3. range/format: PNG dims as specified; WAV header + duration in bounds
"$PY" "$AG" tileset "$T/tiles.png" --seed 5 --size 16 --tiles 8 >/dev/null
"$PY" "$AG" sfx "$T/boom.wav" --kind explosion --seed 5 >/dev/null
fmt=$("$PY" - "$T" <<'EOF'
import sys, wave
from PIL import Image
t = sys.argv[1]
a = Image.open(f"{t}/a1.png"); tl = Image.open(f"{t}/tiles.png")
assert a.size == (64, 16) and a.mode == "RGBA", f"sprite sheet {a.size} {a.mode}"
assert tl.size == (128, 16), f"tileset {tl.size}"
w = wave.open(f"{t}/boom.wav"); d = w.getnframes() / w.getframerate()
assert w.getnchannels() == 1 and w.getsampwidth() == 2 and 0.5 < d < 1.0, f"wav {d}s"
print("FORMATS OK")
EOF
)
if printf '%s' "$fmt" | grep -q "FORMATS OK"; then ok "PNG dims + WAV format/duration in range"
else bad "format check failed: $fmt"; fi

# 4. INTEGRATION: Godot 4 headless loads the generated sprite + tileset + wav
command -v godot >/dev/null || { bad "godot not on PATH — integration not run"; echo; echo "✗ $fail FAILED ($pass passed)"; exit 1; }
cp -r "$HERE/templates/godot-headless" "$T/proj"
cp "$T/a1.png" "$T/proj/sprite.png"; cp "$T/tiles.png" "$T/proj/tiles.png"; cp "$T/boom.wav" "$T/proj/sfx.wav"
cat > "$T/proj/load_assets.gd" <<'EOF'
extends SceneTree
func _init():
    var img = Image.load_from_file("res://sprite.png")
    if img == null or img.get_width() != 64 or img.get_height() != 16:
        push_error("sprite load FAIL"); quit(1); return
    var tiles = Image.load_from_file("res://tiles.png")
    if tiles == null or tiles.get_width() != 128:
        push_error("tileset load FAIL"); quit(1); return
    var f = FileAccess.open("res://sfx.wav", FileAccess.READ)
    if f == null:
        push_error("wav open FAIL"); quit(1); return
    var hdr = f.get_buffer(12)
    if hdr.slice(0, 4).get_string_from_ascii() != "RIFF" or hdr.slice(8, 12).get_string_from_ascii() != "WAVE":
        push_error("wav header FAIL"); quit(1); return
    print("ASSETS OK: sprite %dx%d, tiles %dx%d, wav %d bytes" % [img.get_width(), img.get_height(), tiles.get_width(), tiles.get_height(), f.get_length()])
    quit(0)
EOF
godot --headless --path "$T/proj" --import >/dev/null 2>&1
out=$(godot --headless --path "$T/proj" -s res://load_assets.gd 2>&1)
if printf '%s' "$out" | grep -q "ASSETS OK"; then
  ok "Godot headless loads generated assets ($(printf '%s' "$out" | grep -o 'ASSETS OK.*'))"
else bad "Godot load failed: $(printf '%s' "$out" | tail -2)"; fi

echo
if [ "$fail" = "0" ]; then echo "✓ ALL $pass PASS — asset pipeline trustworthy"; exit 0
else echo "✗ $fail FAILED ($pass passed)"; exit 1; fi
