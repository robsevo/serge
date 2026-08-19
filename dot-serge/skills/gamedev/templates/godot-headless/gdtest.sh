#!/usr/bin/env bash
# Godot headless test runner — CI-friendly. Usage: ./gdtest.sh [project_dir]
# Imports the project (validates resources/scripts), then runs the headless regression test.
set -uo pipefail
PROJ="${1:-$(dirname "$0")}"
command -v godot >/dev/null || { echo "godot not on PATH (install: godotengine.org/download/linux)"; exit 2; }
godot --headless --path "$PROJ" --import >/dev/null 2>&1   # build import cache / validate
out="$(godot --headless --path "$PROJ" -s res://test_headless.gd 2>&1)"
echo "$out" | grep -E "SIGNATURE|RESULT|SCRIPT ERROR|push_error|FAIL"
echo "$out" | grep -q "RESULT: PASS"
